import path from 'path';

type Config = {
  port: number;
  registry: string;
  tmpdir: string;
  url: string;
  storageBackend: 'gcs' | 's3';
  redis: {
    url: string;
  };
  aws?: {
    access_key: string;
    secret_key: string;
  };
  s3?: {
    bucket: string;
    imports_bucket: string;
    region: string;
  };
  gcs?: {
    projectId: string;
    bucket: string;
    imports_bucket: string;
  };
  cloudfront: { url: string };
  api: { url: string };
  sentry?: { dsn: string };
};

function env(varName: string, testValue?: string): string {
  const envVar = process.env[varName];
  if (!envVar) {
    if (process.env.NODE_ENV === 'test' || process.argv[1].endsWith('cli.js')) {
      return testValue ?? 'noop';
    }
    throw new Error(`environment variable ${varName} isn't specified`);
  }
  return envVar;
}

function optionalEnv(varName: string, defaultValue?: string): string | undefined {
  return process.env[varName] || defaultValue;
}

// Determine storage backend based on environment variables
const useGCS = !!process.env.GCS_PROJECT_ID || !!process.env.USE_GCS;

const config: Config = {
  registry: 'https://registry.yarnpkg.com',
  port: parseInt(process.env.PORT ?? '3012', 10),
  tmpdir: path.join(process.env.TMPDIR ?? '/tmp', 'snackager'),
  url: env('IMPORT_SERVER_URL'),
  storageBackend: useGCS ? 'gcs' : 's3',
  redis: {
    url: env('REDIS_URL'),
  },
  cloudfront: {
    url: env('CLOUDFRONT_URL'),
  },
  api: {
    url: env('API_SERVER_URL', 'https://test.exp.host'),
  },
};

// Configure storage backend
if (useGCS) {
  config.gcs = {
    projectId: env('GCS_PROJECT_ID'),
    bucket: env('GCS_BUCKET'),
    imports_bucket: env('GCS_IMPORTS_BUCKET'),
  };
} else {
  config.aws = {
    access_key: env('AWS_ACCESS_KEY_ID'),
    secret_key: env('AWS_SECRET_ACCESS_KEY'),
  };
  config.s3 = {
    bucket: env('S3_BUCKET'),
    imports_bucket: env('IMPORTS_S3_BUCKET'),
    region: env('S3_REGION'),
  };
}

if (!process.env.DISABLE_INSTRUMENTATION && process.env.NODE_ENV === 'production') {
  config.sentry = {
    dsn: env('SENTRY_DSN'),
  };
}

export default config;
