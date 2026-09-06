const express = require('express');
const jwt = require('jsonwebtoken');
const bcrypt = require('bcryptjs');
const { Pool } = require('pg');
const redis = require('redis');
const cors = require('cors');
const helmet = require('helmet');
const morgan = require('morgan');
const rateLimit = require('express-rate-limit');
const prometheus = require('prom-client');

// Initialize Express app
const app = express();
app.set('trust proxy', 1); // behind ALB: derive client IP from X-Forwarded-For
const PORT = process.env.PORT || 3001;
const JWT_SECRET = process.env.JWT_SECRET || 'your_secret_key';
const JWT_EXPIRY = process.env.JWT_EXPIRY || '24h';
const NODE_ENV = process.env.NODE_ENV || 'development';
const LOG_LEVEL = process.env.LOG_LEVEL || 'info';
const SERVICE_NAME = process.env.SERVICE_NAME || 'auth-service';

// ============= CONFIGURATION =============
// PostgreSQL Connection Pool
const pgPool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: 20,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 2000,
});

// Redis Client
const redisClient = redis.createClient({
  url: process.env.REDIS_URL,
  socket: {
    reconnectStrategy: (retries) => Math.min(retries * 50, 500),
  },
});

redisClient.on('error', (err) => console.error('Redis Client Error', err));
redisClient.connect();

// Prometheus Metrics
const httpRequestDuration = new prometheus.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.1, 0.5, 1, 2, 5],
});

const httpRequestsTotal = new prometheus.Counter({
  name: 'http_requests_total',
  help: 'Total number of HTTP requests',
  labelNames: ['method', 'route', 'status_code'],
});

const loginAttemptsCounter = new prometheus.Counter({
  name: 'auth_login_attempts_total',
  help: 'Total number of login attempts',
  labelNames: ['status'], // 'success' or 'failure'
});

prometheus.register.registerMetric(httpRequestDuration);
prometheus.register.registerMetric(httpRequestsTotal);
prometheus.register.registerMetric(loginAttemptsCounter);

// ============= MIDDLEWARE =============
app.use(helmet());
app.use(cors({
  origin: process.env.ALLOWED_ORIGINS?.split(',') || ['http://localhost:3000', 'http://localhost:8080'],
  credentials: true,
}));

// Request logging
const morganFormat = NODE_ENV === 'development' ? 'dev' : 'combined';
app.use(morgan(morganFormat, {
  skip: (req) => req.path === '/health' || req.path === '/metrics',
}));

// Request body parsing
app.use(express.json({ limit: '1mb' }));
app.use(express.urlencoded({ limit: '1mb', extended: true }));

// Rate limiting
const limiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 100, // limit each IP to 100 requests per windowMs
  message: 'Too many requests from this IP, please try again later.',
  standardHeaders: true,
  legacyHeaders: false,
  store: new (require('rate-limit-redis'))({
    sendCommand: (...args) => redisClient.sendCommand(args),
    prefix: 'rate-limit:',
  }),
});

const loginLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 5, // 5 attempts per 15 minutes
  skipSuccessfulRequests: true,
  store: new (require('rate-limit-redis'))({
    sendCommand: (...args) => redisClient.sendCommand(args),
    prefix: 'login-limit:',
  }),
});

app.use(limiter);

// Prometheus metrics middleware
app.use((req, res, next) => {
  const start = Date.now();
  
  res.on('finish', () => {
    const duration = (Date.now() - start) / 1000;
    httpRequestDuration.labels(req.method, req.route?.path || req.path, res.statusCode).observe(duration);
    httpRequestsTotal.labels(req.method, req.route?.path || req.path, res.statusCode).inc();
  });
  
  next();
});

// ============= LOGGER UTILITY =============
const logger = {
  info: (msg, data = {}) => console.log(JSON.stringify({ level: 'info', timestamp: new Date().toISOString(), service: SERVICE_NAME, msg, ...data })),
  error: (msg, err = {}) => console.error(JSON.stringify({ level: 'error', timestamp: new Date().toISOString(), service: SERVICE_NAME, msg, error: err.message, stack: err.stack })),
  debug: (msg, data = {}) => LOG_LEVEL === 'debug' && console.log(JSON.stringify({ level: 'debug', timestamp: new Date().toISOString(), service: SERVICE_NAME, msg, ...data })),
  warn: (msg, data = {}) => console.warn(JSON.stringify({ level: 'warn', timestamp: new Date().toISOString(), service: SERVICE_NAME, msg, ...data })),
};

// ============= DATABASE INITIALIZATION =============
async function initializeDatabase() {
  try {
    logger.info('Initializing database...');
    
    const client = await pgPool.connect();
    try {
      // Create users table
      await client.query(`
        CREATE TABLE IF NOT EXISTS users (
          id SERIAL PRIMARY KEY,
          email VARCHAR(255) UNIQUE NOT NULL,
          password_hash VARCHAR(255) NOT NULL,
          name VARCHAR(255) NOT NULL,
          status VARCHAR(50) DEFAULT 'active',
          mfa_enabled BOOLEAN DEFAULT FALSE,
          last_login TIMESTAMP,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
          updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
      `);

      // Create refresh tokens table
      await client.query(`
        CREATE TABLE IF NOT EXISTS refresh_tokens (
          id SERIAL PRIMARY KEY,
          user_id INTEGER NOT NULL REFERENCES users(id),
          token VARCHAR(500) NOT NULL UNIQUE,
          expires_at TIMESTAMP NOT NULL,
          revoked BOOLEAN DEFAULT FALSE,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
      `);

      // Create audit log table
      await client.query(`
        CREATE TABLE IF NOT EXISTS auth_audit_log (
          id SERIAL PRIMARY KEY,
          user_id INTEGER,
          event_type VARCHAR(100) NOT NULL,
          ip_address VARCHAR(45),
          user_agent TEXT,
          status VARCHAR(50),
          details JSONB,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
      `);

      // Postgres: indexes are separate statements (inline INDEX is MySQL-only)
      await client.query('CREATE INDEX IF NOT EXISTS idx_users_email ON users(email)');
      await client.query('CREATE INDEX IF NOT EXISTS idx_rt_user_id ON refresh_tokens(user_id)');
      await client.query('CREATE INDEX IF NOT EXISTS idx_rt_expires_at ON refresh_tokens(expires_at)');
      await client.query('CREATE INDEX IF NOT EXISTS idx_audit_user_id ON auth_audit_log(user_id)');
      await client.query('CREATE INDEX IF NOT EXISTS idx_audit_created_at ON auth_audit_log(created_at)');

      logger.info('Database tables created/verified successfully');
    } finally {
      client.release();
    }
  } catch (err) {
    logger.error('Database initialization failed', err);
    process.exit(1);
  }
}

// ============= ROUTES =============

// Health check endpoint
app.get('/health', async (req, res) => {
  try {
    // Check database connection
    const dbCheck = await pgPool.query('SELECT NOW()');
    const dbHealthy = !!dbCheck.rows[0];

    // Check Redis connection
    const redisHealthy = redisClient.isOpen;

    const status = dbHealthy && redisHealthy ? 'healthy' : 'degraded';
    const statusCode = dbHealthy && redisHealthy ? 200 : 503;

    res.status(statusCode).json({
      status,
      timestamp: new Date().toISOString(),
      service: SERVICE_NAME,
      checks: {
        database: dbHealthy ? 'ok' : 'failed',
        redis: redisHealthy ? 'ok' : 'failed',
      },
    });
  } catch (err) {
    logger.error('Health check failed', err);
    res.status(503).json({
      status: 'unhealthy',
      error: err.message,
    });
  }
});

// Metrics endpoint
app.get('/metrics', async (req, res) => {
  res.set('Content-Type', prometheus.register.contentType);
  res.end(await prometheus.register.metrics());
});

// Register endpoint
app.post('/v1/auth/register', async (req, res) => {
  const { email, password, name } = req.body;
  const startTime = Date.now();

  try {
    // Validation
    if (!email || !password || !name) {
      return res.status(400).json({ error: 'Missing required fields' });
    }

    if (password.length < 8) {
      return res.status(400).json({ error: 'Password must be at least 8 characters' });
    }

    // Check if user already exists
    const existingUser = await pgPool.query('SELECT id FROM users WHERE email = $1', [email]);
    if (existingUser.rows.length > 0) {
      await logAuditEvent(null, 'REGISTER_ATTEMPT', req, 'failed', { reason: 'user_exists' });
      return res.status(409).json({ error: 'User already exists' });
    }

    // Hash password
    const passwordHash = await bcrypt.hash(password, 10);

    // Create user
    const result = await pgPool.query(
      'INSERT INTO users (email, password_hash, name, status) VALUES ($1, $2, $3, $4) RETURNING id, email, name',
      [email, passwordHash, name, 'active']
    );

    const user = result.rows[0];
    await logAuditEvent(user.id, 'USER_REGISTERED', req, 'success');

    logger.info('User registered successfully', { userId: user.id, email });

    res.status(201).json({
      message: 'User registered successfully',
      user: {
        id: user.id,
        email: user.email,
        name: user.name,
      },
    });
  } catch (err) {
    logger.error('Registration failed', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// Login endpoint
app.post('/v1/auth/login', loginLimiter, async (req, res) => {
  const { email, password } = req.body;

  try {
    if (!email || !password) {
      return res.status(400).json({ error: 'Email and password required' });
    }

    // Get user by email
    const userResult = await pgPool.query('SELECT id, email, name, password_hash FROM users WHERE email = $1', [email]);
    
    if (userResult.rows.length === 0) {
      loginAttemptsCounter.labels('failure').inc();
      await logAuditEvent(null, 'LOGIN_ATTEMPT', req, 'failed', { reason: 'user_not_found' });
      return res.status(401).json({ error: 'Invalid credentials' });
    }

    const user = userResult.rows[0];

    // Verify password
    const passwordMatch = await bcrypt.compare(password, user.password_hash);
    if (!passwordMatch) {
      loginAttemptsCounter.labels('failure').inc();
      await logAuditEvent(user.id, 'LOGIN_ATTEMPT', req, 'failed', { reason: 'invalid_password' });
      return res.status(401).json({ error: 'Invalid credentials' });
    }

    // Generate tokens
    const accessToken = jwt.sign(
      { userId: user.id, email: user.email, type: 'access' },
      JWT_SECRET,
      { expiresIn: JWT_EXPIRY, issuer: SERVICE_NAME }
    );

    const refreshToken = jwt.sign(
      { userId: user.id, email: user.email, type: 'refresh' },
      JWT_SECRET,
      { expiresIn: '7d', issuer: SERVICE_NAME }
    );

    // Store refresh token
    await pgPool.query(
      'INSERT INTO refresh_tokens (user_id, token, expires_at) VALUES ($1, $2, $3)',
      [user.id, refreshToken, new Date(Date.now() + 7 * 24 * 60 * 60 * 1000)]
    );

    // Update last login
    await pgPool.query('UPDATE users SET last_login = NOW() WHERE id = $1', [user.id]);

    loginAttemptsCounter.labels('success').inc();
    await logAuditEvent(user.id, 'LOGIN_SUCCESS', req, 'success');

    logger.info('User logged in successfully', { userId: user.id, email });

    res.json({
      message: 'Login successful',
      accessToken,
      refreshToken,
      user: {
        id: user.id,
        email: user.email,
        name: user.name,
      },
    });
  } catch (err) {
    logger.error('Login failed', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// Token refresh endpoint
app.post('/v1/auth/refresh', async (req, res) => {
  const { refreshToken } = req.body;

  try {
    if (!refreshToken) {
      return res.status(400).json({ error: 'Refresh token required' });
    }

    // Verify refresh token
    const decoded = jwt.verify(refreshToken, JWT_SECRET);
    
    // Check if token is still valid in database
    const tokenResult = await pgPool.query(
      'SELECT id FROM refresh_tokens WHERE token = $1 AND revoked = FALSE AND expires_at > NOW()',
      [refreshToken]
    );

    if (tokenResult.rows.length === 0) {
      await logAuditEvent(decoded.userId, 'TOKEN_REFRESH_FAILED', req, 'failed', { reason: 'invalid_token' });
      return res.status(401).json({ error: 'Invalid or expired refresh token' });
    }

    // Generate new access token
    const newAccessToken = jwt.sign(
      { userId: decoded.userId, email: decoded.email, type: 'access' },
      JWT_SECRET,
      { expiresIn: JWT_EXPIRY, issuer: SERVICE_NAME }
    );

    await logAuditEvent(decoded.userId, 'TOKEN_REFRESHED', req, 'success');

    res.json({
      message: 'Token refreshed successfully',
      accessToken: newAccessToken,
    });
  } catch (err) {
    logger.error('Token refresh failed', err);
    res.status(401).json({ error: 'Invalid refresh token' });
  }
});

// Verify token endpoint
app.post('/v1/auth/verify', async (req, res) => {
  const { token } = req.body;

  try {
    if (!token) {
      return res.status(400).json({ error: 'Token required' });
    }

    const decoded = jwt.verify(token, JWT_SECRET);
    res.json({
      valid: true,
      user: {
        userId: decoded.userId,
        email: decoded.email,
      },
    });
  } catch (err) {
    res.status(401).json({
      valid: false,
      error: 'Invalid token',
    });
  }
});

// ============= UTILITY FUNCTIONS =============
async function logAuditEvent(userId, eventType, req, status, details = {}) {
  try {
    await pgPool.query(
      'INSERT INTO auth_audit_log (user_id, event_type, ip_address, user_agent, status, details) VALUES ($1, $2, $3, $4, $5, $6)',
      [
        userId,
        eventType,
        req.ip || req.connection.remoteAddress,
        req.get('user-agent'),
        status,
        JSON.stringify(details),
      ]
    );
  } catch (err) {
    logger.error('Failed to log audit event', err);
  }
}

// ============= ERROR HANDLING =============
app.use((err, req, res, next) => {
  logger.error('Unhandled error', err);
  res.status(500).json({
    error: 'Internal server error',
    requestId: req.id,
  });
});

// 404 handler
app.use((req, res) => {
  res.status(404).json({
    error: 'Not found',
  });
});

// ============= SERVER STARTUP =============
async function startServer() {
  try {
    await initializeDatabase();
    
    app.listen(PORT, () => {
      logger.info(`${SERVICE_NAME} started successfully`, {
        port: PORT,
        environment: NODE_ENV,
      });
    });
  } catch (err) {
    logger.error('Failed to start server', err);
    process.exit(1);
  }
}

// Handle graceful shutdown
process.on('SIGTERM', async () => {
  logger.info('SIGTERM received, shutting down gracefully...');
  await pgPool.end();
  await redisClient.quit();
  process.exit(0);
});

process.on('SIGINT', async () => {
  logger.info('SIGINT received, shutting down gracefully...');
  await pgPool.end();
  await redisClient.quit();
  process.exit(0);
});

// Start the server
startServer();

module.exports = app;

