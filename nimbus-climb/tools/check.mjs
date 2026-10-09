#!/usr/bin/env node
// check.mjs - static checks for the Nimbus Climb Lua sources (uses the `luaparse` npm package).
//
// Usage:
//   node tools/check.mjs [--json] [--quiet] [--strict] [paths...]      (default path: src)
//
// Errors (exit code 1):
//   syntax              the file must parse as plain Lua 5.1 (this also rejects Luau-only syntax:
//                       type annotations, `continue`, `+=`, `if a then b else c` expressions,
//                       backtick strings, `//`, `goto`, bitwise operators...). A hint is printed.
//   undefined-global    a global that is not a Lua / Roblox built-in (typos, locals used before
//                       their declaration, forgotten requires...).
//   global-write        assignment to a global / `function foo()` without `local`.
//   deprecated-global   wait( spawn( delay( - use task.wait / task.spawn / task.delay.
//   raw-font            Enum.Font, Font.new..., `.Font = "Name"` outside shared/Theme.lua.
//   not-in-roblox       loadstring, io, package, dofile ... which do not exist in Roblox.
//   unknown-service     game:GetService("Typo").
//   unknown-class       Instance.new("Typo") - Roblox errors for classes that cannot be created.
//   bad-require         require(script.Parent.Missing) / require(Shared.Missing).
//   module-return       a ModuleScript that does not end with `return <value>`.
//   too-many-locals     more than 200 active locals in one function (does not compile).
//   contract            a public member listed in tools/contract.json is not defined.
//   asset-id            an asset id / web URL outside Config.Art (rbxassetid://, rbxthumb://, http(s)://). The only
//                       asset the game may reference is the player's own upload, Config.Art.StormfangImage
//                       (tools/contract.json v3.artImage); built-in rbxasset:// content is fine.
//   wrong-context       a client-only API in server code (RenderStepped, BindToRenderStep, LocalPlayer, FireServer,
//                       OnClientEvent, UserInputService, ...) or a server-only API in client code (OnServerEvent,
//                       FireClient, FireAllClients, BindToClose, DataStoreService, ServerStorage, ...).
// Warnings (printed, exit code 0 unless --strict):
//   many-locals, loop-no-yield, deprecated-api, contract (dynamic modules).

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

let luaparse;
try {
	luaparse = (await import("luaparse")).default;
} catch (err) {
	console.error("check.mjs: the 'luaparse' package is missing. Run:  cd tools && npm install");
	process.exit(2);
}

const TOOLS_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(TOOLS_DIR, "..");

// ---------------------------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------------------------
const args = process.argv.slice(2);
const flags = new Set(args.filter((a) => a.startsWith("--")));
const inputs = args.filter((a) => !a.startsWith("--"));
const asJson = flags.has("--json");
const quiet = flags.has("--quiet");
const strict = flags.has("--strict");

// ---------------------------------------------------------------------------------------------
// Allow lists
// ---------------------------------------------------------------------------------------------
const ROBLOX_GLOBALS = new Set(
	(
		"assert collectgarbage error gcinfo getfenv getmetatable ipairs newproxy next pairs pcall print " +
		"rawequal rawget rawlen rawset require select setfenv setmetatable tonumber tostring type typeof " +
		"unpack xpcall _G _VERSION warn bit32 buffer coroutine debug math os string table utf8 task " +
		"tick time wait spawn delay elapsedTime version settings stats UserSettings " +
		"script game workspace shared " +
		"Axes BrickColor CFrame CatalogSearchParams Color3 ColorSequence ColorSequenceKeypoint DateTime " +
		"Enum Faces FloatCurveKey Font Instance NumberRange NumberSequence NumberSequenceKeypoint " +
		"OverlapParams PathWaypoint PhysicalProperties RaycastParams Random Ray Rect Region3 Region3int16 " +
		"SharedTable TweenInfo UDim UDim2 Vector2 Vector2int16 Vector3 Vector3int16"
	).split(/\s+/)
);

// Real Roblox globals that must not be used in this project.
const DEPRECATED_GLOBALS = {
	wait: "task.wait",
	spawn: "task.spawn",
	delay: "task.delay",
	Wait: "task.wait",
	Spawn: "task.spawn",
	Delay: "task.delay",
};

// Standard Lua globals / functions that do not exist (or are disabled) in Roblox.
const NOT_IN_ROBLOX_GLOBALS = new Set(["loadstring", "load", "dofile", "loadfile", "io", "package", "module", "arg"]);
const NOT_IN_ROBLOX_MEMBERS = {
	os: new Set(["execute", "exit", "getenv", "remove", "rename", "tmpname", "setlocale"]),
	debug: new Set(["sethook", "gethook", "getlocal", "setlocal", "getupvalue", "setupvalue", "getregistry", "getmetatable", "setmetatable", "getinfo", "upvalueid", "upvaluejoin", "getuservalue", "setuservalue"]),
	table: new Set(["getn", "maxn", "setn", "foreach", "foreachi"]),
	string: new Set(["gfind"]),
	math: new Set(["mod", "ldexp", "frexp", "cosh", "sinh", "tanh", "log10x"]),
};

// Real service / class names live in tools/roblox-api.json (shared with the runtime mock).
let robloxApi = { services: [], creatableClasses: [] };
try {
	robloxApi = JSON.parse(fs.readFileSync(path.join(TOOLS_DIR, "roblox-api.json"), "utf8"));
} catch (err) {
	console.error("check.mjs: cannot read tools/roblox-api.json: " + err.message);
	process.exit(2);
}
const KNOWN_SERVICES = new Set(robloxApi.services);
const KNOWN_CLASSES = new Set(robloxApi.creatableClasses);

const DEPRECATED_METHODS = {
	connect: "Connect",
	disconnect: "Disconnect",
	wait: "Wait (or task.wait)",
	isA: "IsA",
	findFirstChild: "FindFirstChild",
	getChildren: "GetChildren",
	clone: "Clone",
	remove: "Destroy",
	Remove: "Destroy",
	children: "GetChildren",
};

const DEPRECATED_CLASSES = {
	BodyVelocity: "LinearVelocity",
	BodyPosition: "AlignPosition",
	BodyGyro: "AlignOrientation",
	BodyForce: "VectorForce",
	BodyThrust: "VectorForce",
	BodyAngularVelocity: "AngularVelocity",
	Hat: "Accessory",
	Message: "a ScreenGui text label",
	Hint: "a ScreenGui text label",
};

// Members / services that only work on one side of the client-server boundary (src/server vs src/client).
const CLIENT_ONLY_MEMBERS = new Set(["RenderStepped", "BindToRenderStep", "UnbindFromRenderStep", "LocalPlayer", "FireServer", "OnClientEvent", "CurrentCamera"]);
const CLIENT_ONLY_SERVICES = new Set(["UserInputService", "ContextActionService", "GuiService", "HapticService", "VRService"]);
const SERVER_ONLY_MEMBERS = new Set(["OnServerEvent", "FireClient", "FireAllClients", "BindToClose", "OnServerInvoke"]);
const SERVER_ONLY_SERVICES = new Set(["DataStoreService", "ServerStorage", "ServerScriptService", "MessagingService", "MemoryStoreService"]);

// Asset ids and web URLs (built-in rbxasset:// content is not an asset upload).
const ASSET_PATTERN = /rbxassetid:\/\/|rbxthumb:\/\/|https?:\/\/|roblox\.com\/asset/i;

const DEPRECATED_MEMBERS = {
	Velocity: "AssemblyLinearVelocity (BasePart.Velocity is deprecated)",
	RotVelocity: "AssemblyAngularVelocity (BasePart.RotVelocity is deprecated)",
};

// ---------------------------------------------------------------------------------------------
// Contract (tools/contract.json) + project file listing
// ---------------------------------------------------------------------------------------------
let contract = { modules: {} };
try {
	contract = JSON.parse(fs.readFileSync(path.join(TOOLS_DIR, "contract.json"), "utf8"));
} catch (err) {
	// optional: the checks below simply skip the contract rule
}

function listLua(p) {
	const out = [];
	const stat = fs.statSync(p);
	if (stat.isDirectory()) {
		for (const entry of fs.readdirSync(p, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
			if (entry.name === "node_modules" || entry.name.startsWith(".")) continue;
			out.push(...listLua(path.join(p, entry.name)));
		}
	} else if (p.endsWith(".lua")) {
		out.push(p);
	}
	return out;
}

const targets = (inputs.length ? inputs : ["src"]).map((p) => path.resolve(process.cwd(), p));
const srcRoot = path.join(ROOT, "src");
const files = [];
for (const t of targets) {
	if (!fs.existsSync(t)) {
		console.error("check.mjs: path not found: " + t);
		process.exit(2);
	}
	files.push(...listLua(t));
}

// The `src` directory that contains `file` (so copies of the project in other folders are checked too).
function srcRootOf(file) {
	const norm = file.replace(/\\/g, "/");
	const idx = norm.lastIndexOf("/src/");
	return idx >= 0 ? file.slice(0, idx + 4) : srcRoot;
}

// Names of ModuleScripts that exist as siblings (for require checks).
function moduleExists(dir, name) {
	return (
		fs.existsSync(path.join(dir, name + ".lua")) ||
		fs.existsSync(path.join(dir, name + ".server.lua")) ||
		fs.existsSync(path.join(dir, name + ".client.lua")) ||
		fs.existsSync(path.join(dir, name, "init.lua")) ||
		(fs.existsSync(path.join(dir, name)) && fs.statSync(path.join(dir, name)).isDirectory())
	);
}

// ---------------------------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------------------------
const findings = []; // { file, line, col, severity, rule, message }
let currentFile = "";

function rel(file) {
	return path.relative(process.cwd(), file) || file;
}

function report(node, severity, rule, message) {
	const loc = node && node.loc ? node.loc.start : { line: 0, column: 0 };
	findings.push({
		file: rel(currentFile),
		line: loc.line,
		col: loc.column + 1,
		severity,
		rule,
		message,
	});
}

// ---------------------------------------------------------------------------------------------
// Helpers over the AST
// ---------------------------------------------------------------------------------------------
function isId(node, name) {
	return node && node.type === "Identifier" && (name === undefined || node.name === name);
}

function isGlobalId(node, name) {
	return isId(node, name) && node.isLocal === false;
}

function strValue(node) {
	if (!node || node.type !== "StringLiteral") return null;
	if (typeof node.value === "string") return node.value;
	if (node.raw && node.raw.length >= 2) return node.raw.slice(1, -1);
	return null;
}

// Name of `x.y.z` / `x:y` chains rooted at a global: returns ["x","y","z"] or null.
function dottedPath(node) {
	const parts = [];
	let cur = node;
	while (cur && cur.type === "MemberExpression") {
		parts.unshift(cur.identifier.name);
		cur = cur.base;
	}
	if (isId(cur)) {
		parts.unshift(cur.name);
		return parts;
	}
	return null;
}

function callArgs(node) {
	if (node.type === "CallExpression") return node.arguments;
	if (node.type === "StringCallExpression") return [node.argument];
	if (node.type === "TableCallExpression") return [node.arguments];
	return [];
}

function* childNodes(node) {
	for (const key of Object.keys(node)) {
		if (key === "loc" || key === "range" || key === "comments" || key === "globals") continue;
		const v = node[key];
		if (Array.isArray(v)) {
			for (const item of v) if (item && typeof item === "object" && item.type) yield item;
		} else if (v && typeof v === "object" && v.type) {
			yield v;
		}
	}
}

// Does any node below `node` satisfy pred? (does not descend into nested function bodies if stopAtFn)
function anyNode(node, pred, stopAtFn) {
	if (pred(node)) return true;
	for (const child of childNodes(node)) {
		if (stopAtFn && child.type === "FunctionDeclaration") continue;
		if (anyNode(child, pred, stopAtFn)) return true;
	}
	return false;
}

// ---------------------------------------------------------------------------------------------
// Luau hints for syntax errors
// ---------------------------------------------------------------------------------------------
function luauHint(sourceLine) {
	const l = sourceLine || "";
	if (/(^|[^.])\.\.=|[+\-*\/%^]=(?!=)/.test(l.replace(/==|~=|<=|>=/g, "  "))) return "compound assignment (+= -= *= /= ..=) is Luau-only; write x = x + 1";
	if (/^\s*continue\b/.test(l)) return "`continue` is Luau-only; wrap the rest of the loop body in an `if` instead";
	if (/`/.test(l)) return "backtick strings are Luau-only; use string concatenation or string.format";
	if (/\blocal\s+[A-Za-z_][\w]*\s*:\s*[A-Za-z_{(]/.test(l) || /\bfunction\b[^)]*\([^)]*[A-Za-z_]\s*:\s*[A-Za-z_{(]/.test(l) || /\)\s*:\s*[A-Za-z_{(][\w.<>?|&{}, ]*\s*$/.test(l)) {
		return "type annotations are Luau-only; remove them";
	}
	if (/(=|\(|return|,)\s*if\b.*\bthen\b.*\belse\b/.test(l)) return "if-expressions are Luau-only; use an if statement or `a and b or c`";
	if (/[^\/]\/\/[^\/]/.test(l)) return "`//` (floor division) is not Lua 5.1; use math.floor(a / b)";
	if (/\bgoto\b|::\w+::/.test(l)) return "goto/labels are not Lua 5.1; restructure the loop";
	if (/[&|~]|<<|>>/.test(l.replace(/~=/g, ""))) return "bitwise operators are not Lua 5.1; use bit32";
	if (/\b0b[01_]+\b|\b\d+_\d+\b/.test(l)) return "binary literals / digit separators are Luau-only";
	return null;
}

// ---------------------------------------------------------------------------------------------
// Per-file analysis
// ---------------------------------------------------------------------------------------------
function analyse(file) {
	currentFile = file;
	let source = fs.readFileSync(file, "utf8");
	if (source.charCodeAt(0) === 0xfeff) source = source.slice(1);
	const lines = source.split(/\r?\n/);

	let ast;
	try {
		ast = luaparse.parse(source, { luaVersion: "5.1", scope: true, locations: true, comments: false });
	} catch (err) {
		const message = String(err.message || err).replace(/^\[\d+:\d+\]\s*/, "");
		const hint = luauHint(lines[(err.line || 1) - 1]);
		findings.push({
			file: rel(file),
			line: err.line || 0,
			col: (err.column || 0) + 1,
			severity: "error",
			rule: "syntax",
			message: message + (hint ? "  [hint: " + hint + "]" : ""),
		});
		return;
	}

	const base = path.basename(file);
	const isTheme = base === "Theme.lua" && path.basename(path.dirname(file)) === "shared";
	const isConfig = base === "Config.lua" && path.basename(path.dirname(file)) === "shared";
	const normPath = file.replace(/\\/g, "/");
	const side = /\/src\/server\//.test(normPath) ? "server" : /\/src\/client\//.test(normPath) ? "client" : "shared";
	const allowedArt = contract.v3 && typeof contract.v3.artImage === "string" ? contract.v3.artImage : null;
	const isScript = base.endsWith(".server.lua") || base.endsWith(".client.lua");
	const dir = path.dirname(file);
	const sharedVars = new Set(); // local names bound to ReplicatedStorage.Shared

	// -- ModuleScript must end with `return <expr>` ------------------------------------------
	if (!isScript) {
		const last = ast.body[ast.body.length - 1];
		if (!last || last.type !== "ReturnStatement" || last.arguments.length !== 1) {
			report(last || ast, "error", "module-return", "a ModuleScript must end with `return <exactly one value>`");
		}
	}

	// -- first pass: find `local X = <something>:WaitForChild("Shared")` -----------------------
	(function findShared(node) {
		if (node.type === "LocalStatement") {
			node.init.forEach((init, i) => {
				if (init && init.type === "CallExpression" && init.base.type === "MemberExpression") {
					const name = init.base.identifier.name;
					const arg = strValue(init.arguments[0]);
					if ((name === "WaitForChild" || name === "FindFirstChild") && arg === "Shared" && node.variables[i]) {
						sharedVars.add(node.variables[i].name);
					}
				}
			});
		}
		for (const c of childNodes(node)) findShared(c);
	})(ast);

	// -- main walk ----------------------------------------------------------------------------
	function checkRequire(call) {
		const arg = callArgs(call)[0];
		if (!arg) return;
		// require(script.Parent.Parent.Name)
		const p = arg.type === "MemberExpression" ? dottedPath(arg) : null;
		if (p && p[0] === "script" && p.length >= 3 && p.slice(1, -1).every((x) => x === "Parent")) {
			let d = dir;
			for (let i = 0; i < p.length - 3; i++) d = path.dirname(d); // script.Parent == dir
			if (!moduleExists(d, p[p.length - 1])) {
				report(call, "error", "bad-require", "require(" + p.join(".") + "): no sibling module '" + p[p.length - 1] + "' in " + rel(d));
			}
			return;
		}
		// require(Shared.Name) / require(Shared:WaitForChild("Name"))
		let name = null;
		if (p && p.length === 2 && sharedVars.has(p[0])) name = p[1];
		if (arg.type === "CallExpression" && arg.base.type === "MemberExpression" && isId(arg.base.base) && sharedVars.has(arg.base.base.name)) {
			const m = arg.base.identifier.name;
			if (m === "WaitForChild" || m === "FindFirstChild") name = strValue(arg.arguments[0]);
		}
		if (name && !moduleExists(path.join(srcRootOf(file), "shared"), name)) {
			report(call, "error", "bad-require", "require(Shared." + name + "): no module src/shared/" + name + ".lua");
		}
	}

	function checkCall(node) {
		const callee = node.base;
		const args2 = callArgs(node);

		// Deprecated / banned global functions.
		if (isId(callee) && callee.isLocal === false) {
			if (DEPRECATED_GLOBALS[callee.name]) {
				report(callee, "error", "deprecated-global", callee.name + "( is deprecated; use " + DEPRECATED_GLOBALS[callee.name] + "(");
			}
			if (callee.name === "require") checkRequire(node);
		}

		if (callee.type === "MemberExpression") {
			const method = callee.identifier.name;
			// game:GetService("Name")
			if (callee.indexer === ":" && method === "GetService") {
				const s = strValue(args2[0]);
				if (s && !KNOWN_SERVICES.has(s)) report(node, "error", "unknown-service", "GetService(\"" + s + "\") is not a known Roblox service");
				if (s && side === "server" && CLIENT_ONLY_SERVICES.has(s)) report(node, "error", "wrong-context", "GetService(\"" + s + "\") is client-only; server code must not use it");
				if (s && side === "client" && SERVER_ONLY_SERVICES.has(s)) report(node, "error", "wrong-context", "GetService(\"" + s + "\") is server-only; client code cannot use it");
			}
			// lowercase / removed methods
			if (callee.indexer === ":" && Object.prototype.hasOwnProperty.call(DEPRECATED_METHODS, method)) {
				report(callee.identifier, "warning", "deprecated-api", ":" + method + "() is deprecated; use :" + DEPRECATED_METHODS[method] + "()");
			}
			// Instance.new("Class")
			const dp = dottedPath(callee);
			if (dp && dp.length === 2 && (dp[0] === "Instance" || dp[0] === "Util") && (dp[1] === "new" || dp[1] === "Create")) {
				const cls = strValue(args2[0]);
				if (cls) {
					if (DEPRECATED_CLASSES[cls]) report(node, "warning", "deprecated-api", dp[0] + "." + dp[1] + "(\"" + cls + "\") is deprecated; use " + DEPRECATED_CLASSES[cls]);
					else if (!KNOWN_CLASSES.has(cls)) report(node, "error", "unknown-class", dp[0] + "." + dp[1] + "(\"" + cls + "\") fails in Roblox: not a creatable class (typo? see tools/roblox-api.json)");
				}
			}
			// os.execute / debug.sethook / table.getn ...
			if (dp && dp.length === 2 && NOT_IN_ROBLOX_MEMBERS[dp[0]] && NOT_IN_ROBLOX_MEMBERS[dp[0]].has(dp[1]) && isGlobalId(callee.base, dp[0])) {
				report(node, "error", "not-in-roblox", dp[0] + "." + dp[1] + " does not exist in Roblox");
			}
			// Font.new / Font.fromEnum ...
			if (!isTheme && isGlobalId(callee.base, "Font")) {
				report(node, "error", "raw-font", "Font." + method + "(...) bypasses Theme; use Theme.Style / Theme.Label / Theme.Fonts.<Role>");
			}
		}
	}

	function checkMember(node) {
		const member = node.identifier.name;
		if (side === "server" && CLIENT_ONLY_MEMBERS.has(member)) {
			report(node.identifier, "error", "wrong-context", "." + member + " is client-only (server code; per-frame visuals belong on the client)");
		} else if (side === "client" && SERVER_ONLY_MEMBERS.has(member)) {
			report(node.identifier, "error", "wrong-context", "." + member + " is server-only (client code)");
		}
		// Enum.Font outside Theme
		if (!isTheme && isGlobalId(node.base, "Enum") && node.identifier.name === "Font") {
			report(node, "error", "raw-font", "Enum.Font is only allowed in shared/Theme.lua; use Theme.Style / Theme.Label / Theme.Fonts.<Role>");
		}
		if (DEPRECATED_MEMBERS[node.identifier.name] && node.indexer === ".") {
			report(node.identifier, "warning", "deprecated-api", "." + node.identifier.name + " -> use " + DEPRECATED_MEMBERS[node.identifier.name]);
		}
	}

	function visit(node) {
		switch (node.type) {
			case "MemberExpression":
				checkMember(node);
				visit(node.base);
				return;
			case "IndexExpression": {
				const k = strValue(node.index);
				if (!isTheme && k === "Font" && isGlobalId(node.base, "Enum")) {
					report(node, "error", "raw-font", "Enum[\"Font\"] is only allowed in shared/Theme.lua");
				}
				visit(node.base);
				visit(node.index);
				return;
			}
			case "StringLiteral": {
				const v = strValue(node);
				if (v && ASSET_PATTERN.test(v)) {
					if (!isConfig) {
						report(node, "error", "asset-id", "asset id / URL '" + v.slice(0, 60) + "' outside Config.Art; reference Config.Art.StormfangImage instead (the only allowed asset)");
					} else if (allowedArt && v !== allowedArt) {
						report(node, "error", "asset-id", "asset id / URL '" + v.slice(0, 60) + "' in Config: the only allowed asset is " + allowedArt + " (Config.Art.StormfangImage)");
					}
				}
				return;
			}
			case "TableKeyString":
				if (!isTheme && node.key.name === "Font" && node.value && (node.value.type === "StringLiteral" || node.value.type === "NumericLiteral")) {
					report(node, "error", "raw-font", "`Font = <literal>` bypasses Theme; use Theme.Style / Theme.Label");
				}
				visit(node.value);
				return;
			case "TableKey":
				visit(node.key);
				visit(node.value);
				return;
			case "FunctionDeclaration":
				if (node.identifier) {
					if (node.identifier.type === "Identifier") {
						if (node.identifier.isLocal === false) {
							report(node.identifier, "error", "global-write", "`function " + node.identifier.name + "` defines a global; add `local`");
						}
					} else {
						visit(node.identifier);
					}
				}
				for (const stmt of node.body) visit(stmt);
				return;
			case "AssignmentStatement":
				node.variables.forEach((v, i) => {
					if (v.type === "Identifier") {
						if (v.isLocal === false) report(v, "error", "global-write", "assignment to undeclared global '" + v.name + "' (missing `local`?)");
					} else {
						visit(v);
						// x.Font = "Name"
						if (!isTheme && v.type === "MemberExpression" && v.identifier.name === "Font") {
							const init = node.init[i];
							if (init && (init.type === "StringLiteral" || init.type === "NumericLiteral")) {
								report(v, "error", "raw-font", "`.Font = <literal>` bypasses Theme; use Theme.Style / Theme.Label");
							}
						}
					}
				});
				node.init.forEach(visit);
				return;
			case "Identifier":
				if (node.isLocal === false) {
					if (!ROBLOX_GLOBALS.has(node.name)) {
						if (NOT_IN_ROBLOX_GLOBALS.has(node.name)) {
							report(node, "error", "not-in-roblox", "'" + node.name + "' does not exist in Roblox");
						} else {
							report(node, "error", "undefined-global", "undefined global '" + node.name + "'");
						}
					} else if (DEPRECATED_GLOBALS[node.name] && !node._call) {
						report(node, "error", "deprecated-global", node.name + " is deprecated; use " + DEPRECATED_GLOBALS[node.name]);
					} else if (node.name === "Font" && !isTheme && !node._call) {
						report(node, "error", "raw-font", "the Font datatype bypasses Theme");
					}
				}
				return;
			case "CallExpression":
			case "StringCallExpression":
			case "TableCallExpression":
				if (isId(node.base)) node.base._call = true; // reported by checkCall instead
				checkCall(node);
				break;
			case "WhileStatement":
			case "RepeatStatement":
				break;
			default:
				break;
		}
		for (const c of childNodes(node)) visit(c);
	}

	// loop-no-yield: `while true do` / `repeat ... until false` with nothing that can yield or exit.
	const YIELD_NAMES = new Set(["wait", "Wait", "yield", "WaitForChild"]);
	function isYieldCall(n) {
		if (n.type !== "CallExpression" && n.type !== "StringCallExpression" && n.type !== "TableCallExpression") return false;
		const p = n.base.type === "MemberExpression" ? dottedPath(n.base) : null;
		const name = p ? p[p.length - 1] : isId(n.base) ? n.base.name : "";
		return YIELD_NAMES.has(name);
	}
	function exitsOrYields(n, inFn) {
		if (!inFn && (n.type === "BreakStatement" || n.type === "ReturnStatement")) return true;
		if (isYieldCall(n)) return true;
		for (const c of childNodes(n)) if (exitsOrYields(c, inFn || c.type === "FunctionDeclaration")) return true;
		return false;
	}
	function checkLoops(stmts) {
		for (const s of stmts) {
			const forever =
				(s.type === "WhileStatement" && s.condition.type === "BooleanLiteral" && s.condition.value === true) ||
				(s.type === "RepeatStatement" && s.condition.type === "BooleanLiteral" && s.condition.value === false);
			if (forever && !s.body.some((b) => exitsOrYields(b, false))) {
				report(s, "warning", "loop-no-yield", "endless loop without task.wait / break / return would freeze the script");
			}
		}
	}
	(function blocks(node) {
		if (Array.isArray(node.body)) checkLoops(node.body);
		for (const c of childNodes(node)) blocks(c);
	})(ast);

	for (const stmt of ast.body) visit(stmt);

	// -- local variable limit -----------------------------------------------------------------
	(function locals() {
		function fn(node, paramCount) {
			const st = { active: paramCount, max: paramCount };
			block(node.body, st);
			if (st.max > 200) report(node, "error", "too-many-locals", "function has " + st.max + " active local variables (Lua/Luau limit is 200)");
			else if (st.max >= 160) report(node, "warning", "many-locals", "function has " + st.max + " active local variables (limit is 200)");
		}
		function block(stmts, st) {
			const saved = st.active;
			for (const s of stmts) stmt(s, st);
			st.active = saved;
		}
		function bump(st, n) {
			st.active += n;
			if (st.active > st.max) st.max = st.active;
		}
		function expr(node, st) {
			if (!node || typeof node !== "object") return;
			if (node.type === "FunctionDeclaration") {
				fn(node, node.parameters.length + (node.identifier && node.identifier.type === "MemberExpression" && node.identifier.indexer === ":" ? 1 : 0));
				return;
			}
			for (const c of childNodes(node)) expr(c, st);
		}
		function stmt(s, st) {
			switch (s.type) {
				case "LocalStatement":
					s.init.forEach((e) => expr(e, st));
					bump(st, s.variables.length);
					return;
				case "FunctionDeclaration":
					if (s.isLocal) bump(st, 1);
					expr(s, st);
					return;
				case "DoStatement":
					block(s.body, st);
					return;
				case "WhileStatement":
					expr(s.condition, st);
					block(s.body, st);
					return;
				case "RepeatStatement":
					block(s.body, st);
					return;
				case "IfStatement":
					for (const clause of s.clauses) {
						if (clause.condition) expr(clause.condition, st);
						block(clause.body, st);
					}
					return;
				case "ForNumericStatement": {
					[s.start, s.end, s.step].forEach((e) => expr(e, st));
					const saved = st.active;
					bump(st, 4);
					block(s.body, st);
					st.active = saved;
					return;
				}
				case "ForGenericStatement": {
					s.iterators.forEach((e) => expr(e, st));
					const saved = st.active;
					bump(st, 3 + s.variables.length);
					block(s.body, st);
					st.active = saved;
					return;
				}
				default:
					expr(s, st);
			}
		}
		fn({ body: ast.body, loc: ast.loc }, 0);
	})();

	// -- contract -----------------------------------------------------------------------------
	checkContract(file, ast);
}

// ---------------------------------------------------------------------------------------------
// Contract: collect the public names a module defines (static, best effort)
// ---------------------------------------------------------------------------------------------
function checkContract(file, ast) {
	const m = file.replace(/\\/g, "/").match(/(?:^|\/)src\/(.+)\.lua$/);
	const relToSrc = m ? m[1] : "";
	const entry = contract.modules && contract.modules[relToSrc];
	if (!entry) return;
	const last = ast.body[ast.body.length - 1];
	if (!last || last.type !== "ReturnStatement" || last.arguments.length !== 1) return; // reported elsewhere
	const ret = last.arguments[0];

	const defined = new Set();
	let dynamic = false;
	let tableName = null;

	function addCtor(ctor) {
		for (const f of ctor.fields) {
			if (f.type === "TableKeyString") defined.add(f.key.name);
			else if (f.type === "TableKey" && f.key.type === "StringLiteral") defined.add(strValue(f.key));
			else if (f.type === "TableKey") dynamic = true;
		}
	}

	if (ret.type === "Identifier") tableName = ret.name;
	else if (ret.type === "TableConstructorExpression") addCtor(ret);
	else dynamic = true; // returns a call (e.g. setmetatable) - cannot know

	for (const s of ast.body) {
		if (s.type === "LocalStatement" && tableName) {
			s.variables.forEach((v, i) => {
				const init = s.init[i];
				if (v.name === tableName && init && init.type === "TableConstructorExpression") addCtor(init);
				else if (v.name === tableName && init) dynamic = true; // e.g. local M = setmetatable({}, ...)
			});
		}
		if (s.type === "FunctionDeclaration" && s.identifier && s.identifier.type === "MemberExpression") {
			const b = s.identifier.base;
			if (isId(b, tableName)) defined.add(s.identifier.identifier.name);
		}
		if (s.type === "AssignmentStatement") {
			for (const v of s.variables) {
				if (v.type === "MemberExpression" && isId(v.base, tableName)) defined.add(v.identifier.name);
				if (v.type === "IndexExpression" && isId(v.base, tableName)) {
					const k = strValue(v.index);
					if (k) defined.add(k);
					else dynamic = true;
				}
			}
		}
		// loops that fill the table dynamically (for ... do M[name] = ...)
		if (s.type === "ForGenericStatement" || s.type === "ForNumericStatement" || s.type === "DoStatement") {
			if (anyNode(s, (n) => n.type === "AssignmentStatement" && n.variables.some((v) => v.type === "IndexExpression" && isId(v.base, tableName)), false)) dynamic = true;
		}
	}
	// Member assignment inside nested blocks (e.g. `if x then M.Foo = ... end`).
	if (tableName) {
		(function deep(node) {
			if (node.type === "AssignmentStatement") {
				for (const v of node.variables) if (v.type === "MemberExpression" && isId(v.base, tableName)) defined.add(v.identifier.name);
			}
			for (const c of childNodes(node)) deep(c);
		})(ast);
	}

	const wanted = [...(entry.functions || []), ...(entry.signals || []), ...(entry.fields || [])];
	for (const name of wanted) {
		if (!defined.has(name)) {
			const sev = dynamic ? "warning" : "error";
			report(last, sev, "contract", "public member '" + name + "' (ARCHITECTURE.md / _V2 / _V3, tools/contract.json) is not defined" + (dynamic ? " (module fills its table dynamically; verify at runtime)" : ""));
		}
	}
}

// ---------------------------------------------------------------------------------------------
// Run
// ---------------------------------------------------------------------------------------------
for (const f of files) {
	try {
		analyse(f);
	} catch (err) {
		findings.push({ file: rel(f), line: 0, col: 0, severity: "error", rule: "internal", message: "check.mjs crashed on this file: " + (err && err.stack ? err.stack : err) });
	}
}

const errors = findings.filter((f) => f.severity === "error");
const warnings = findings.filter((f) => f.severity !== "error");

if (asJson) {
	console.log(JSON.stringify({ files: files.length, errors: errors.length, warnings: warnings.length, findings }, null, 2));
} else {
	const order = (a, b) => (a.file === b.file ? a.line - b.line || a.col - b.col : a.file.localeCompare(b.file));
	for (const f of [...errors].sort(order)) {
		console.log(`${f.file}:${f.line}:${f.col}  error    ${f.rule.padEnd(17)} ${f.message}`);
	}
	if (!quiet) {
		for (const f of [...warnings].sort(order)) {
			console.log(`${f.file}:${f.line}:${f.col}  warning  ${f.rule.padEnd(17)} ${f.message}`);
		}
	}
	console.log(`checked ${files.length} files: ${errors.length} error(s), ${warnings.length} warning(s)`);
}

process.exit(errors.length > 0 || (strict && warnings.length > 0) ? 1 : 0);
