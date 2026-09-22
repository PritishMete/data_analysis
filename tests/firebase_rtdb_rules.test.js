const assert = require("node:assert/strict");
const { initializeTestEnvironment, assertSucceeds, assertFails } = require("@firebase/rules-unit-testing");
const fs = require("node:fs");

const projectId = "insightflow-5a23d";
let env;
const users = {
  alice: { localId: "alice", email: "alice@example.test" },
  bob: { localId: "bob", email: "bob@example.test" },
  suspended: { localId: "suspended", email: "suspended@example.test" }
};

function db(uid) {
  return env.authenticatedContext(uid).database();
}
function seedDb() {
  return env.withSecurityRulesDisabled(async context => {
    await context.database().ref().set({
      users: {
        alice: { suspended: false },
        bob: { suspended: false },
        suspended: { suspended: true }
      },
      workspaces: {
        a: {
          members: { alice: { roles: { analyst: true } } },
          roles: { analyst: { permissions: ["data.view"] } },
          resources: { r1: { grants: { alice: { permissions: { "data.view": true } } }, value: "private-a" } }
        },
        b: {
          members: { bob: { roles: { analyst: true } } },
          roles: { analyst: { permissions: ["data.view"] } },
          resources: { r2: { grants: { bob: { permissions: { "data.view": true } } }, value: "private-b" } }
        }
      }
    });
  });
}

describe("InsightFlow RTDB security rules", () => {
  before(async () => {
    env = await initializeTestEnvironment({
      projectId,
      database: { host: "127.0.0.1", port: 9000, rules: fs.readFileSync("database.rules.json", "utf8") }
    });
    await seedDb();
  });
  after(async () => env.cleanup());

  it("denies unauthenticated reads and all client writes", async () => {
    const unauth = env.unauthenticatedContext().database();
    await assertFails(unauth.ref("users/alice").once("value"));
    await assertFails(db("alice").ref("users/alice").set({ suspended: true }));
    await assertFails(db("alice").ref("workspaces/a/members/bob").set({ roles: { owner: true } }));
    await assertFails(db("alice").ref("workspaces/a/resources/r1/grants/alice").set({ permissions: { "data.view": true } }));
  });

  it("allows a user to read only their own non-sensitive authorization records", async () => {
    await assertSucceeds(db("alice").ref("users/alice").once("value"));
    await assertFails(db("alice").ref("users/bob").once("value"));
    await assertSucceeds(db("alice").ref("workspaces/a/members/alice").once("value"));
    await assertFails(db("alice").ref("workspaces/a/members/bob").once("value"));
    await assertSucceeds(db("alice").ref("workspaces/a/resources/r1/grants/alice").once("value"));
    await assertFails(db("alice").ref("workspaces/a/resources/r1/grants/bob").once("value"));
  });

  it("blocks suspended users, cross-workspace access and missing membership", async () => {
    await assertFails(db("suspended").ref("users/suspended").once("value"));
    await assertFails(db("alice").ref("workspaces/b/members/bob").once("value"));
    await assertFails(db("alice").ref("workspaces/b/resources/r2/grants/bob").once("value"));
  });

  it("does not expose workspace roles or bootstrap metadata to clients", async () => {
    await assertFails(db("alice").ref("workspaces/a/roles").once("value"));
    await assertFails(db("alice").ref("workspaces/a/bootstrap").once("value"));
  });
});
