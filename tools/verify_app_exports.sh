#!/bin/zsh
# Checks what the app itself exported in the booted simulator, using tools that aren't this app.
# Run after WorkflowUITests/testFullWorkflow, or after exporting by hand there.
#
#   CHECK_TOOLS=<folder with node_modules/gltf-validator> tools/verify_app_exports.sh
set -euo pipefail
root=${0:A:h:h}
blender=${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}
container=$(xcrun simctl get_app_container booted com.audreyserene.littlesurface data)
out=$(mktemp -d)
cp "$container"/tmp/Exports/*.(obj|glb) "$out"/
for file in "$out"/*.(obj|glb); do echo "$(stat -f %z "$file") bytes  ${file:t}"; done

"$blender" --background --factory-startup --python "$root/tools/blender_check.py" -- "$out"/*.(obj|glb)(N) 2>&1 | grep '^BLENDER' | cut -c9-

# The OBJ header says what the app believed it wrote.
for file in "$out"/*.obj; do
  echo "${file:t} header: $(sed -n 2p "$file")"
  echo "${file:t} faces: $(grep -c '^f ' "$file"), wire edges: $(grep -c '^l ' "$file" || true), objects: $(grep -c '^o ' "$file")"
done

if [[ -n "${CHECK_TOOLS:-}" ]]; then
  cd "$CHECK_TOOLS"
  for file in "$out"/*.glb; do
    node -e "
      const v = require('gltf-validator'), fs = require('fs');
      v.validateBytes(new Uint8Array(fs.readFileSync(process.argv[1]))).then(r => {
        console.log(process.argv[1].split('/').pop(), 'glTF validator: errors', r.issues.numErrors, 'warnings', r.issues.numWarnings);
        if (r.issues.numErrors) process.exitCode = 1;
      });" "$file"
  done
fi
echo "Files: $out"
