(function () {
  "use strict";

  let mutationAuthorization = null;

  window.insightflowSetMutationAuthorization = function (
    idToken,
    workspaceId,
    resourceId,
    action,
    backendBaseUrl
  ) {
    mutationAuthorization = {
      idToken: String(idToken || ""),
      workspaceId: String(workspaceId || ""),
      resourceId: String(resourceId || ""),
      action: String(action || ""),
      backendBaseUrl: String(backendBaseUrl || ""),
    };
  };

  window.insightflowClearMutationAuthorization = function () {
    mutationAuthorization = null;
  };

  window.insightflowRequireMutationAuthorization = async function (override) {
    const authz = override || mutationAuthorization;
    if (
      !authz ||
      !authz.idToken ||
      !authz.workspaceId ||
      !authz.resourceId ||
      !authz.action ||
      !authz.backendBaseUrl
    ) {
      return false;
    }

    try {
      const response = await fetch(
        authz.backendBaseUrl.replace(/\/$/, "") + "/v1/authz/check",
        {
          method: "POST",
          headers: {
            "Authorization": "Bearer " + authz.idToken,
            "Content-Type": "application/json",
            "X-InsightFlow-Workspace-ID": authz.workspaceId,
            "X-InsightFlow-Resource-ID": authz.resourceId,
          },
          body: JSON.stringify({
            workspace_id: authz.workspaceId,
            action: authz.action,
            resource_id: authz.resourceId,
          }),
          credentials: "omit",
          cache: "no-store",
        }
      );
      return response.status === 200;
    } catch (_) {
      // Fail closed: no network response means no Excel mutation.
      return false;
    }
  };
})();
