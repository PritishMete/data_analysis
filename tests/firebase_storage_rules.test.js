const fs = require('fs');
const {
  assertFails,
  initializeTestEnvironment,
} = require('@firebase/rules-unit-testing');

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
    await assertFails(
      context.storage().ref(
        'organizations/org/datasets/ds_1/versions/v1/source',
      ).getMetadata(),
    );
  });

  it('denies direct authenticated client writes', async () => {
    const context = env.authenticatedContext('manager');
    await assertFails(
      context.storage().ref(
        'organizations/org/datasets/ds_1/versions/v1/source',
      ).putString('test'),
    );
  });

  it('denies unauthenticated client writes', async () => {
    const context = env.unauthenticatedContext();
    await assertFails(
      context.storage().ref(
        'organizations/org/datasets/ds_1/versions/v1/source',
      ).putString('test'),
    );
  });
});
