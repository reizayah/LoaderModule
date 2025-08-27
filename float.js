// split-lua-functions.js
// Usage: node split-lua-functions.js <input.lua> <outDir>
const fs = require("fs");
const path = require("path");
const luaparse = require("luaparse");

if (process.argv.length < 4) {
  console.error("Usage: node split-lua-functions.js <input.lua> <outDir>");
  process.exit(1);
}

const inPath = path.resolve(process.argv[2]);
const outDir = path.resolve(process.argv[3]);
const code = fs.readFileSync(inPath, "utf8");
fs.mkdirSync(outDir, { recursive: true });

/**
 * Parse once with ranges so we can cut substrings directly from the source.
 * (Roblox uses Luau; luaparse handles standard Lua 5.1+ well enough for most code.
 * If you hit Luau-specific syntax, swap out the parser or add a Luau prepass.)
 */
const ast = luaparse.parse(code, {
  luaVersion: "5.1",
  locations: true,
  ranges: true,
  comments: false,
});

/** Helpers **/

function fullNameFromIdentifier(id) {
  // Builds a readable symbol name for files + placeholders: "Util:scale", "Foo.run", "add"
  if (!id) return "anonymous";
  if (id.type === "Identifier") return id.name;
  if (id.type === "MemberExpression") {
    const base = fullNameFromIdentifier(id.base);
    const idx = id.indexer || "."; // "." or ":"
    return `${base}${idx}${id.identifier.name}`;
  }
  return "unknown";
}

function printableFromIdentifier(id) {
  // Rebuilds the *code text* for the left-hand side (foo, Util:scale, Foo.run)
  if (id.type === "Identifier") return id.name;
  if (id.type === "MemberExpression") {
    const base = printableFromIdentifier(id.base);
    const idx = id.indexer || ".";
    return `${base}${idx}${id.identifier.name}`;
  }
  throw new Error("Unsupported identifier: " + id.type);
}

function slugForFile(name) {
  // Turn "Util:scale" -> "Util_scale", "Foo.run" -> "Foo_run"
  return name.replace(/[^a-zA-Z0-9_:.]/g, "_").replace(/[:.]/g, "_");
}

function paramsToList(params) {
  return params.map(p => (p.type === "Identifier" ? p.name : "...")).join(", ");
}

function buildWrapperForDeclaration(node, symbol) {
  // node: FunctionDeclaration
  const paramList = paramsToList(node.parameters || []);
  const nameCode = printableFromIdentifier(node.identifier);
  const isLocal = node.isLocal ? "local " : "";
  // We preserve the original header and swap the body with a require call.
  return `${isLocal}function ${nameCode}(${paramList})
  return require(__ASSET_ID_${slugForFile(symbol)}__ )(${paramList})
end`;
}

function buildWrapperForAssignment(isLocal, lhsCode, funcNode, symbol) {
  // funcNode: FunctionExpression with parameters
  const paramList = paramsToList(funcNode.parameters || []);
  const localKw = isLocal ? "local " : "";
  return `${localKw}${lhsCode} = function(${paramList})
  return require(__ASSET_ID_${slugForFile(symbol)}__ )(${paramList})
end`;
}

function extractModuleCodeForDeclaration(node) {
  // Use the original slice and rewrite the header to "return function(..."
  const src = code.slice(node.range[0], node.range[1]);

  // Replace "local function name(" or "function name(" with "return function("
  const replaced =
    src.replace(/^\s*local\s+function\s+[^\(]+\s*\(/, "return function(") ||
    src.replace(/^\s*function\s+[^\(]+\s*\(/, "return function(");

  // If neither regex matched (e.g., whitespace quirks), fall back to reconstructing minimally:
  if (!/^\s*return\s+function\s*\(/.test(replaced)) {
    const fallback = `return function(${paramsToList(node.parameters || [])})
${indentBodyFromNodeBody(node.body)}
end`;
    return fallback;
  }
  return replaced;
}

function extractModuleCodeForFunctionExpression(funcNode) {
  // Grab "function(...) ... end" directly then prefix with "return "
  const raw = code.slice(funcNode.range[0], funcNode.range[1]);
  if (/^\s*function\b/.test(raw)) return "return " + raw;
  // Extremely rare if parser printed "anonymous func" differently; fallback:
  return `return function(${paramsToList(funcNode.parameters || [])})
${indentBodyFromNodeBody(funcNode.body || [])}
end`;
}

function indentBodyFromNodeBody(bodyStatements, indent = "") {
  // Very small helper to reconstruct a stub body if slicing failed (keeps the demo robust).
  // We don't pretty-print the original; this only triggers on pathological headers.
  // For demo purposes we just put a comment.
  return `${indent}-- original body moved to module`;
}

/** 1) Find all top-level functions we want to split **/

const replacements = []; // {start, end, text}
const modules = [];      // {name, filename, text}

for (const node of ast.body) {
  // Case A: function foo() ... end   OR   function T:bar() ... end
  if (node.type === "FunctionDeclaration") {
    const symbol = fullNameFromIdentifier(node.identifier);
    const moduleText = extractModuleCodeForDeclaration(node);
    const wrapperText = buildWrapperForDeclaration(node, symbol);

    const fileBase = slugForFile(symbol);
    modules.push({
      name: symbol,
      filename: `${fileBase}.lua`,
      text: moduleText.trim() + "\n",
    });

    replacements.push({
      start: node.range[0],
      end: node.range[1],
      text: wrapperText,
    });
    continue;
  }

  // Case B: local foo = function() ... end
  if (node.type === "LocalStatement") {
    if (
      node.init &&
      node.init.length === 1 &&
      node.init[0] &&
      node.init[0].type === "FunctionExpression" &&
      node.variables &&
      node.variables.length === 1 &&
      node.variables[0].type === "Identifier"
    ) {
      const funcNode = node.init[0];
      const lhs = node.variables[0];
      const symbol = lhs.name;
      const moduleText = extractModuleCodeForFunctionExpression(funcNode);
      const wrapperText = buildWrapperForAssignment(true, lhs.name, funcNode, symbol);

      modules.push({
        name: symbol,
        filename: `${slugForFile(symbol)}.lua`,
        text: moduleText.trim() + "\n",
      });

      replacements.push({
        start: node.range[0],
        end: node.range[1],
        text: wrapperText,
      });
    }
    continue;
  }

  // Case C: foo = function() ... end   OR   Foo.run = function() ... end
  if (node.type === "AssignmentStatement") {
    if (
      node.init &&
      node.init.length === 1 &&
      node.init[0].type === "FunctionExpression" &&
      node.variables &&
      node.variables.length === 1 &&
      (node.variables[0].type === "Identifier" ||
        node.variables[0].type === "MemberExpression")
    ) {
      const funcNode = node.init[0];
      const lhs = node.variables[0];
      const symbol = fullNameFromIdentifier(lhs);
      const lhsCode = printableFromIdentifier(lhs);
      const moduleText = extractModuleCodeForFunctionExpression(funcNode);
      const wrapperText = buildWrapperForAssignment(false, lhsCode, funcNode, symbol);

      modules.push({
        name: symbol,
        filename: `${slugForFile(symbol)}.lua`,
        text: moduleText.trim() + "\n",
      });

      replacements.push({
        start: node.range[0],
        end: node.range[1],
        text: wrapperText,
      });
    }
    continue;
  }
}

/** 2) Write module files **/
for (const m of modules) {
  fs.writeFileSync(path.join(outDir, m.filename), m.text, "utf8");
  console.log("Wrote module:", m.filename);
}

/** 3) Apply replacements to original source (from end to start to keep indices valid) */
let newCode = code;
replacements
  .sort((a, b) => b.start - a.start)
  .forEach(r => {
    newCode = newCode.slice(0, r.start) + r.text + newCode.slice(r.end);
  });

fs.writeFileSync(path.join(outDir, "modified.lua"), newCode, "utf8");
console.log("Wrote:", path.join(outDir, "modified.lua"));
