import storageClient, { artifactsBucket, UploadResult } from '../external/storage';

export default async function uploadFile(
  key: string,
  body: Buffer,
): Promise<UploadResult | undefined> {
  return await storageClient.uploadFile(artifactsBucket, key, body, {
    acl: 'public-read',
    cacheControl: 'public, max-age=31536000',
  });
}
