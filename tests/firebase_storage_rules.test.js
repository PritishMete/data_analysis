const fs = require('fs');
const {
  assertFails,
  initializeTestEnvironment,
} = require('@firebase/rules-unit-testing');
const { ref, getMetadata, uploadBytes } = require('firebase/storage');

describe('Firebase Storage rules', () => {
  let env;

  before(async () => {
    env = await initializeTestEnvironment({
      projectId: 'insightflow-5a23d',
      storage: {
        rules: fs.readFileSync('storage.rules', 'utf8'),
      },
    });
  });

  after(async () => {
    await env.cleanup();
  });

  it('denies direct authenticated client reads', async () => {
    const context = env.authenticatedContext('employee-a');
    await assertFails(getMetadata(ref(context.storage(), 'organizations/org/datasets/ds_1/versions/v1/source')));
  });

  it('denies direct authenticated client writes', async () => {
    const context = env.authenticatedContext('manager');
    await assertFails(uploadBytes(
      ref(context.storage(), 'organizations/org/datasets/ds_1/versions/v1/source'),
      new Uint8Array([1, 2, 3]),
    ));
  });

  it('denies unauthenticated client writes', async () => {
    const context = env.unauthenticatedContext();
    await assertFails(uploadBytes(
      ref(context.storage(), 'organizations/org/datasets/ds_1/versions/v1/source'),
      new Uint8Array([1]),
    ));
  });
});
