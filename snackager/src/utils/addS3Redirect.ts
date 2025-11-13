import config from '../config';
import { s3, S3 } from '../external/aws';
import logger from '../logger';

export default async function addS3Redirect(
  key: string,
  destination: string,
): Promise<S3.PutObjectOutput | undefined> {
  // Only works with S3 backend
  if (config.storageBackend !== 's3' || !config.s3) {
    logger.warn({ key, destination }, 'S3 redirect not supported with current storage backend');
    return undefined;
  }
  
  try {
    return await s3
      .putObject({
        Bucket: config.s3.bucket,
        Key: `${key}`,
        Body: '',
        ACL: 'public-read',
        CacheControl: 'no-cache',
        WebsiteRedirectLocation: `/${destination}`,
      })
      .promise();
  } catch (error) {
    logger.error(
      { error, key, destination, bucket: config.s3.bucket },
      'unable to add s3 redirect',
    );
  }
  return undefined;
}
