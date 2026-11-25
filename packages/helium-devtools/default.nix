{
  lib,
  python3Packages,
  nodejs_latest,
  fetchurl,
  fetchFromGitHub,
  buildNpmPackage,
  makeWrapper,
}:

let
  chrome-devtools-mcp = buildNpmPackage rec {
    pname = "chrome-devtools-mcp";
    version = "1.13.0";

    # Published tarball is a rollup bundle; the GitHub tree needs the
    # devtools-frontend submodule plus a TypeScript compile.
    src = fetchurl {
      url = "https://registry.npmjs.org/chrome-devtools-mcp/-/chrome-devtools-mcp-${version}.tgz";
      hash = "sha256-kVjEtKh5LLUirkb3buqpSRzgRhajrpcimhYnfgKkrqQ=";
    };

    # Tarball has no lockfile and no production deps. Drop prepare/dev tooling
    # so npm ci does not try to fetch puppeteer/lighthouse/typescript.
    postPatch = ''
      cat > package.json <<'EOF'
{
  "name": "chrome-devtools-mcp",
  "version": "1.13.0",
  "description": "MCP server for Chrome DevTools",
  "type": "module",
  "bin": {
    "chrome-devtools-mcp": "./out/Default/gen/src/bin/chrome-devtools-mcp.js",
    "chrome-devtools": "./out/Default/gen/src/bin/chrome-devtools.js"
  },
  "main": "./out/Default/gen/src/index.js",
  "files": [
    "out/Default/gen/src",
    "LICENSE",
    "skills",
    "!**/*.tsbuildinfo",
    "!**/*.js.map",
    "!**/*.d.ts",
    "!**/*-tsconfig*.json",
    "!**/*.stamp",
    "!**/*.d"
  ],
  "repository": "ChromeDevTools/chrome-devtools-mcp",
  "author": "Google LLC",
  "license": "Apache-2.0",
  "bugs": {
    "url": "https://github.com/ChromeDevTools/chrome-devtools-mcp/issues"
  },
  "homepage": "https://github.com/ChromeDevTools/chrome-devtools-mcp#readme",
  "mcpName": "io.github.ChromeDevTools/chrome-devtools-mcp",
  "engines": {
    "node": "^20.19.0 || ^22.12.0 || >=23"
  }
}
EOF
      cat > package-lock.json <<'EOF'
{
  "name": "chrome-devtools-mcp",
  "version": "1.13.0",
  "lockfileVersion": 3,
  "requires": true,
  "packages": {
    "": {
      "name": "chrome-devtools-mcp",
      "version": "1.13.0",
      "license": "Apache-2.0",
      "bin": {
        "chrome-devtools": "out/Default/gen/src/bin/chrome-devtools.js",
        "chrome-devtools-mcp": "out/Default/gen/src/bin/chrome-devtools-mcp.js"
      },
      "engines": {
        "node": "^20.19.0 || ^22.12.0 || >=23"
      }
    }
  }
}
EOF
    '';

    forceEmptyCache = true;
    dontNpmBuild = true;
    dontNpmPrune = true;
    # npmInstallHook deletes an empty node_modules/ then cp's it.
    preInstall = ''
      mkdir -p node_modules
      touch node_modules/.keep
    '';

    npmDepsHash = "sha256-/qoNPKmyI+/TInVmLSHUvumptpOEw2JFTkXX3q+/PSI=";
    nodejs = nodejs_latest;
    nativeBuildInputs = [ makeWrapper ];

    # attach_child_tools uses MCP's sanitized stdio env, so parent wrapper
    # vars never reach this process. Bake them into the bin itself.
    postInstall = ''
      wrapProgram $out/bin/chrome-devtools-mcp \
        --set CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS 1 \
        --set CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS 1 \
        --set NODE_OPTIONS "--max-old-space-size=96"
    '';

    meta = {
      description = "Chrome DevTools MCP server";
      homepage = "https://github.com/ChromeDevTools/chrome-devtools-mcp";
    };
  };

  # nixpkgs ships mcp 2.x, which removed FastMCP. This tree is still the v1 API
  # (mcp<2 in pyproject.toml). Pin the last 1.x release until that migration.
  mcp1 = python3Packages.buildPythonPackage rec {
    pname = "mcp";
    # update: skip
    version = "1.30.0";
    pyproject = true;

    src = fetchFromGitHub {
      owner = "modelcontextprotocol";
      repo = "python-sdk";
      tag = "v${version}";
      hash = "sha256-EkmTqsK+vBJcURuwFkhtNJMFgtzgw/7Cd+Fpav4P/ko=";
    };

    build-system = with python3Packages; [
      hatchling
      uv-dynamic-versioning
    ];

    dependencies =
      with python3Packages;
      [
        anyio
        httpx
        httpx-sse
        pydantic
        starlette
        python-multipart
        sse-starlette
        pydantic-settings
        uvicorn
        jsonschema
        pyjwt
        typing-extensions
        typing-inspection
      ]
      ++ pyjwt.optional-dependencies.crypto;

    pythonImportsCheck = [ "mcp" ];
    doCheck = false;
  };

  # stdio_client sanitizes the child env (no PYTHONPATH). The fake MCP server
  # is launched with sys.executable, so the check interpreter must have mcp
  # on its own site-packages.
  pythonForTests = python3Packages.python.withPackages (
    ps: [
      ps.pytest
      ps.pytest-asyncio
      ps.aiohttp
      mcp1
      ps.uvicorn
      ps.starlette
    ]
  );
in
python3Packages.buildPythonApplication rec {
  pname = "helium-devtools";
  version = "0.1.0";
  src = ./.;
  pyproject = true;

  nativeBuildInputs = [
    python3Packages.setuptools
    makeWrapper
  ];

  propagatedBuildInputs = [
    python3Packages.aiohttp
    mcp1
    python3Packages.uvicorn
    python3Packages.starlette
  ];

  nativeCheckInputs = with python3Packages; [
    pytestCheckHook
    pytest-asyncio
    pythonForTests
  ];

  pytestFlags = [ "tests" ];

  # pytestCheckHook uses the unwrapped python; the stdio child then cannot
  # import mcp. Run the same tests with pythonForTests so sys.executable works.
  dontUsePytestCheck = true;
  installCheckPhase = ''
    runHook preCheck
    ${pythonForTests.interpreter} -m pytest tests
    runHook postCheck
  '';

  # wrapProgram in postInstall would wrap the unwrapped script; wrapPythonPrograms
  # then skips it (no python shebang) and PYTHONPATH is lost. makeWrapperArgs
  # are applied by wrapPythonPrograms.
  makeWrapperArgs = [
    "--set"
    "HELIUM_DEVTOOLS_CDP_MCP"
    "${chrome-devtools-mcp}/bin/chrome-devtools-mcp"
    "--set"
    "CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS"
    "1"
    "--set"
    "CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS"
    "1"
  ];

  meta = {
    description = "CDP shim + MCP aggregator for daily Helium";
    mainProgram = "helium-devtools";
  };
}
