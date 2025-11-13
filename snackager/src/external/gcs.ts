import { Storage } from '@google-cloud/storage';
import config from '../config';

// Create GCS client
export const storage = new Storage({
  projectId: config.gcs?.projectId,
});

export { Storage };

// Get bucket instances
export const artifactsBucket = storage.bucket(config.gcs?.bucket || '');
export const importsBucket = storage.bucket(config.gcs?.imports_bucket || '');

