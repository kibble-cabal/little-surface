#!/bin/zsh
# Exports the acceptance workflow's result, then checks the files with tools that aren't this app:
# Blender's importers, trimesh and the Khronos glTF validator.
#
#   CHECK_TOOLS=<folder with venv/ and node_modules/> tools/verify_export.sh
set -euo pipefail
root=${0:A:h:h}
tools=${CHECK_TOOLS:?Set CHECK_TOOLS to the folder with venv/ and node_modules/gltf-validator}
blender=${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}
out=$(mktemp -d)

(cd "$root/Core" && LS_EXPORT_DIR="$out" swift test --filter WorkflowTests 2>&1 | tail -1)
"$blender" --background --factory-startup --python "$root/tools/blender_check.py" -- \
  "$out/workflow.obj" "$out/workflow.glb" "$out/workflow_with_source.obj" "$out/workflow_with_source.glb" > "$out/blender.log" 2>&1
grep '^BLENDER' "$out/blender.log"
"$tools/venv/bin/python" "$root/tools/check_files.py" "$out" "$out/blender.log"
cd "$tools"
node -e "
const v = require('gltf-validator'), fs = require('fs');
(async () => {
  for (const f of ['workflow.glb', 'workflow_with_source.glb']) {
    const r = await v.validateBytes(new Uint8Array(fs.readFileSync('$out/' + f)));
    console.log('gltf-validator', f, 'errors', r.issues.numErrors, 'warnings', r.issues.numWarnings, 'infos', r.issues.numInfos);
    for (const m of r.issues.messages.filter(m => m.severity <= 1).slice(0, 10)) console.log(' ', m.code, m.message, m.pointer);
    if (r.issues.numErrors) process.exitCode = 1;
  }
})();
"
echo "Files: $out"
