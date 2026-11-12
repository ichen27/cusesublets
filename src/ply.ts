// Reads the room mesh the processor writes (processing/room_mesh.py write_ply): binary
// little-endian; float x,y,z + uchar red,green,blue per vertex; uchar-count int triangles.
export interface ColoredMesh {
  positions: Float32Array;
  /** RGBA, 0–255. */
  colors: Uint8Array;
  indices: Uint32Array;
}

const EXPECTED =
  /^ply\nformat binary_little_endian 1\.0\n(?:comment [^\n]*\n)*element vertex (\d+)\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nelement face (\d+)\nproperty list uchar int vertex_indices\nend_header\n/;

export function parsePly(buffer: ArrayBuffer): ColoredMesh {
  const head = new TextDecoder("ascii").decode(new Uint8Array(buffer, 0, Math.min(buffer.byteLength, 2048)));
  const match = head.match(EXPECTED);
  if (!match) throw new Error("Unsupported mesh format");
  const vertexCount = Number(match[1]);
  const faceCount = Number(match[2]);
  const start = match[0].length;
  if (buffer.byteLength < start + vertexCount * 15 + faceCount * 13) throw new Error("Truncated mesh");
  const view = new DataView(buffer, start);
  const positions = new Float32Array(vertexCount * 3);
  const colors = new Uint8Array(vertexCount * 4);
  let o = 0;
  for (let v = 0; v < vertexCount; v++, o += 15) {
    positions[3 * v] = view.getFloat32(o, true);
    positions[3 * v + 1] = view.getFloat32(o + 4, true);
    positions[3 * v + 2] = view.getFloat32(o + 8, true);
    colors.set([view.getUint8(o + 12), view.getUint8(o + 13), view.getUint8(o + 14), 255], 4 * v);
  }
  const indices = new Uint32Array(faceCount * 3);
  for (let f = 0; f < faceCount; f++, o += 13) {
    if (view.getUint8(o) !== 3) throw new Error("Mesh faces must be triangles");
    for (let i = 0; i < 3; i++) {
      const index = view.getInt32(o + 1 + 4 * i, true);
      if (index < 0 || index >= vertexCount) throw new Error("Mesh index out of range");
      indices[3 * f + i] = index;
    }
  }
  return { positions, colors, indices };
}
