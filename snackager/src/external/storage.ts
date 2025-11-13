/**
 * Storage abstraction layer that supports both AWS S3 and Google Cloud Storage
 */
import config from '../config';
import logger from '../logger';

// S3 imports
import aws from 'aws-sdk';

// GCS imports
import { Storage } from '@google-cloud/storage';

// Types
export interface UploadResult {
  location: string;
  bucket: string;
  key: string;
}

export interface StorageClient {
  uploadFile(bucket: string, key: string, body: Buffer, options?: UploadOptions): Promise<UploadResult | undefined>;
  getFile(bucket: string, key: string): Promise<Buffer | undefined>;
  deleteFile(bucket: string, key: string): Promise<void>;
  fileExists(bucket: string, key: string): Promise<boolean>;
}

export interface UploadOptions {
  contentType?: string;
  cacheControl?: string;
  acl?: string;
}

// S3 Client Implementation
class S3StorageClient implements StorageClient {
  private s3: aws.S3;

  constructor() {
    if (!config.aws || !config.s3) {
      throw new Error('AWS/S3 configuration is required when using S3 storage backend');
    }
    
    aws.config.update({
      accessKeyId: config.aws.access_key,
      secretAccessKey: config.aws.secret_key,
      region: config.s3.region,
    });
    
    this.s3 = new aws.S3();
  }

  async uploadFile(
    bucket: string,
    key: string,
    body: Buffer,
    options?: UploadOptions
  ): Promise<UploadResult | undefined> {
    try {
      const result = await this.s3
        .upload({
          Bucket: bucket,
          Key: key,
          Body: body,
          ACL: options?.acl || 'public-read',
          CacheControl: options?.cacheControl || 'public, max-age=31536000',
          ContentType: options?.contentType,
        })
        .promise();
      
      return {
        location: result.Location,
        bucket: result.Bucket,
        key: result.Key,
      };
    } catch (error) {
      logger.error({ error, key, bucket }, 'unable to upload file to S3');
      return undefined;
    }
  }

  async getFile(bucket: string, key: string): Promise<Buffer | undefined> {
    try {
      const result = await this.s3
        .getObject({
          Bucket: bucket,
          Key: key,
        })
        .promise();
      
      if (result.Body) {
        return result.Body as Buffer;
      }
    } catch (error) {
      // File not found or error
      return undefined;
    }
    return undefined;
  }

  async deleteFile(bucket: string, key: string): Promise<void> {
    try {
      await this.s3
        .deleteObject({
          Bucket: bucket,
          Key: key,
        })
        .promise();
    } catch (error) {
      // Ignore errors
    }
  }

  async fileExists(bucket: string, key: string): Promise<boolean> {
    try {
      await this.s3
        .headObject({
          Bucket: bucket,
          Key: key,
        })
        .promise();
      return true;
    } catch {
      return false;
    }
  }

  getPublicUrl(bucket: string, key: string): string {
    if (!config.s3) {
      throw new Error('S3 configuration is required');
    }
    return `https://s3-${config.s3.region}.amazonaws.com/${bucket}/${encodeURIComponent(key)}`;
  }
}

// GCS Client Implementation
class GCSStorageClient implements StorageClient {
  private storage: Storage;

  constructor() {
    if (!config.gcs) {
      throw new Error('GCS configuration is required when using GCS storage backend');
    }
    
    this.storage = new Storage({
      projectId: config.gcs.projectId,
    });
  }

  async uploadFile(
    bucket: string,
    key: string,
    body: Buffer,
    options?: UploadOptions
  ): Promise<UploadResult | undefined> {
    try {
      const file = this.storage.bucket(bucket).file(key);
      
      await file.save(body, {
        metadata: {
          cacheControl: options?.cacheControl || 'public, max-age=31536000',
          contentType: options?.contentType,
        },
        public: options?.acl === 'public-read',
      });

      // Make file public if requested
      if (options?.acl === 'public-read') {
        await file.makePublic();
      }
      
      return {
        location: `https://storage.googleapis.com/${bucket}/${key}`,
        bucket: bucket,
        key: key,
      };
    } catch (error) {
      logger.error({ error, key, bucket }, 'unable to upload file to GCS');
      return undefined;
    }
  }

  async getFile(bucket: string, key: string): Promise<Buffer | undefined> {
    try {
      const file = this.storage.bucket(bucket).file(key);
      const [contents] = await file.download();
      return contents;
    } catch (error) {
      // File not found or error
      return undefined;
    }
  }

  async deleteFile(bucket: string, key: string): Promise<void> {
    try {
      await this.storage.bucket(bucket).file(key).delete();
    } catch (error) {
      // Ignore errors
    }
  }

  async fileExists(bucket: string, key: string): Promise<boolean> {
    try {
      const file = this.storage.bucket(bucket).file(key);
      const [exists] = await file.exists();
      return exists;
    } catch {
      return false;
    }
  }

  getPublicUrl(bucket: string, key: string): string {
    return `https://storage.googleapis.com/${bucket}/${encodeURIComponent(key)}`;
  }
}

// Create and export the appropriate storage client
let storageClient: (S3StorageClient | GCSStorageClient) & { getPublicUrl(bucket: string, key: string): string };

if (config.storageBackend === 'gcs') {
  logger.info('Using Google Cloud Storage backend');
  storageClient = new GCSStorageClient();
} else {
  logger.info('Using AWS S3 backend');
  storageClient = new S3StorageClient();
}

export default storageClient;

// Export buckets based on backend
export const artifactsBucket = config.storageBackend === 'gcs' 
  ? config.gcs!.bucket 
  : config.s3!.bucket;

export const importsBucket = config.storageBackend === 'gcs'
  ? config.gcs!.imports_bucket
  : config.s3!.imports_bucket;

