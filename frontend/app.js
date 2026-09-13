let sessionId = null;

const fileInput = document.getElementById("file");
const sheetNameInput = document.getElementById("sheetName");
const activeCellInput = document.getElementById("activeCell");
const queryInput = document.getElementById("query");
const output = document.getElementById("output");
const runButton = document.getElementById("runQuery");
const createButton = document.getElementById("createSession");
const detailFilesInput = document.getElementById("detailFiles");
const detailFileStatus = document.getElementById("detailFileStatus");
const detailButton = document.getElementById("runDetailAnalysis");
const detailPathInput = document.getElementById("detailPath");
const pathButton = document.getElementById("runPathAnalysis");
let selectedDetailFiles = [];

const supportedDetailExtensions = new Set([".csv", ".tsv", ".xlsx", ".xlsm", ".xls", ".json"]);

function updateDetailFileStatus(files) {
  selectedDetailFiles = Array.from(files || []);
  if (selectedDetailFiles.length === 0) {
    detailFileStatus.textContent = "No files selected.";
    return;
  }
  const unsupported = selectedDetailFiles.filter((file) => {
    const dot = file.name.lastIndexOf(".");
    return !supportedDetailExtensions.has(dot >= 0 ? file.name.slice(dot).toLowerCase() : "");
  });
  const names = selectedDetailFiles.map((file) => file.name).join(", ");
  const warning = unsupported.length ? ` Unsupported files will be ignored: ${unsupported.map((file) => file.name).join(", ")}.` : "";
  detailFileStatus.textContent = `${selectedDetailFiles.length} file${selectedDetailFiles.length === 1 ? "" : "s"} selected: ${names}.${warning}`;
}

detailFilesInput.addEventListener("change", () => updateDetailFileStatus(detailFilesInput.files));

function setOutput(value) {
  output.textContent = typeof value === "string" ? value : JSON.stringify(value, null, 2);
}

function renderMetaResponse(result) {
  if (!result || result.response_type !== "assistant_meta") return false;
  const wrapper = document.createElement("div");
  const title = document.createElement("h3");
  title.textContent = result.title || "InsightFlow";
  wrapper.appendChild(title);
  const summary = document.createElement("p");
  summary.textContent = result.summary || "";
  wrapper.appendChild(summary);
  for (const section of result.sections || []) {
    const heading = document.createElement("h4");
    heading.textContent = section.title || "";
    wrapper.appendChild(heading);
    const list = document.createElement("ul");
    for (const item of section.items || []) {
      const li = document.createElement("li");
      li.textContent = item;
      list.appendChild(li);
    }
    wrapper.appendChild(list);
  }
  if ((result.examples || []).length) {
    const heading = document.createElement("h4");
    heading.textContent = "Examples";
    wrapper.appendChild(heading);
    const list = document.createElement("ul");
    for (const item of result.examples) {
      const li = document.createElement("li");
      li.textContent = item;
      list.appendChild(li);
    }
    wrapper.appendChild(list);
  }
  if ((result.links || []).length) {
    const links = document.createElement("p");
    result.links.forEach((item, index) => {
      const anchor = document.createElement("a");
      anchor.href = item.url;
      anchor.target = "_blank";
      anchor.rel = "noopener noreferrer";
      anchor.textContent = item.label;
      if (index) links.appendChild(document.createTextNode(" · "));
      links.appendChild(anchor);
    });
    wrapper.appendChild(links);
  }
  output.replaceChildren(wrapper);
  return true;
}

function detailReport(result) {
  if (!result || !result.success || !result.readable_report_html) {
    return result;
  }
  return { __detailHtml: result.readable_report_html };
}

function setDetailOutput(result) {
  const formatted = detailReport(result);
  if (formatted && formatted.__detailHtml) {
    output.innerHTML = formatted.__detailHtml;
  } else {
    setOutput(formatted);
  }
}

createButton.addEventListener("click", async () => {
  const file = fileInput.files && fileInput.files[0];
  if (!file) {
    setOutput("Choose an Excel file first.");
    return;
  }
  const form = new FormData();
  form.append("file", file);
  if (sheetNameInput.value) form.append("sheet_name", sheetNameInput.value);
  if (activeCellInput.value) form.append("active_cell", activeCellInput.value);
  const res = await fetch("/excel/session", { method: "POST", body: form });
  const data = await res.json();
  sessionId = data.session_id;
  setOutput(data);
});

runButton.addEventListener("click", async () => {
  const text = queryInput.value.trim();
  if (!text) {
    setOutput("Enter a question or request first.");
    return;
  }

  // Identity/help/meta questions are intentionally checked before session
  // requirements so they work with zero uploaded data and consume no Gemini quota.
  const metaForm = new FormData();
  metaForm.append("text", text);
  metaForm.append("surface", "excel");
  const metaRes = await fetch("/excel/meta", { method: "POST", body: metaForm });
  const meta = await metaRes.json();
  if (meta && meta.handled) {
    renderMetaResponse(meta);
    return;
  }

  if (!sessionId) {
    setOutput("Create an Excel session before running analytical queries.");
    return;
  }
  const form = new FormData();
  form.append("session_id", sessionId);
  form.append("text", text);
  const res = await fetch("/excel/query", { method: "POST", body: form });
  const data = await res.json();
  if (!renderMetaResponse(data)) setOutput(data);
});

detailButton.addEventListener("click", async () => {
  const files = selectedDetailFiles;
  if (!files || files.length === 0) {
    setOutput("No files selected. Choose one or more dataset files first.");
    return;
  }
  const form = new FormData();
  for (const file of files) form.append("files", file, file.name);
  form.append("source_platform", "web");
  detailButton.disabled = true;
  try {
    const res = await fetch("/v2/detail-analysis", { method: "POST", body: form });
    const result = await res.json();
    if (result.ignored_files && result.ignored_files.length > 0) {
      result.notice = `Ignored unsupported files: ${result.ignored_files.join(", ")}`;
    }
    setDetailOutput(result);
  } catch (error) {
    setOutput(`Detail analysis failed: ${error}`);
  } finally {
    detailButton.disabled = false;
  }
});

pathButton.addEventListener("click", async () => {
  const path = detailPathInput.value.trim();
  if (!path) {
    setOutput("Enter a local folder path first.");
    return;
  }
  const form = new FormData();
  form.append("path", path);
  pathButton.disabled = true;
  try {
    const res = await fetch("/v2/detail-analysis/path", { method: "POST", body: form });
    setDetailOutput(await res.json());
  } catch (error) {
    setOutput(`Local path analysis failed: ${error}`);
  } finally {
    pathButton.disabled = false;
  }
});
