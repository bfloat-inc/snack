import aws from 'aws-sdk';

import config from '../config';

export type { S3 } from 'aws-sdk';

// Only configure AWS if using S3 backend
if (config.storageBackend === 's3' && config.aws && config.s3) {
  aws.config.update({
    accessKeyId: config.aws.access_key,
    secretAccessKey: config.aws.secret_key,
    region: config.s3.region,
  });
}

export function createS3Client(options: aws.S3.ClientConfiguration = {}): aws.S3 {
  if (config.storageBackend !== 's3') {
    throw new Error('S3 client requested but not using S3 storage backend');
  }
  return new aws.S3(options);
}

export const s3 = config.storageBackend === 's3' ? new aws.S3() : ({} as aws.S3);
