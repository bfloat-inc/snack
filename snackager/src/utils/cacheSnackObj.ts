import json5 from 'json5';

import storageClient, { importsBucket } from '../external/storage';
import logger from '../logger';
import { GitSnackObj } from '../types';

export async function getCachedObj(filename: string): Promise<GitSnackObj | undefined> {
  try {
    const buffer = await storageClient.getFile(importsBucket, filename);
    if (!buffer) {
      return undefined;
    }
    return json5.parse(buffer.toString());
  } catch {
    return undefined;
  }
}

export async function cacheObj(snackObj: GitSnackObj, filename: string): Promise<void> {
  try {
    const body = Buffer.from(json5.stringify(snackObj));
    const result = await storageClient.uploadFile(importsBucket, filename, body, {
      acl: 'public-read',
      cacheControl: 'public, max-age=31536000',
    });
    
    if (!result) {
      throw new Error('Failed to upload file');
    }
  } catch (e) {
    logger.error({ e, filename, bucket: importsBucket }, 'unable to upload file to storage');
    throw new Error('CacheObj failure: ' + e.message);
  }
}

export async function removeFromCache(filename: string): Promise<void> {
  try {
    await storageClient.deleteFile(importsBucket, filename);
  } catch {
    // Ignore error
  }
}
