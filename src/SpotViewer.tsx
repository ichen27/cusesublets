import "./spot-viewer.css";
import { useEffect, useRef, useState } from "react";
import * as pc from "playcanvas";
import type { RoomTour } from "../shared/room-tour";
import type { SpotTourResult, TourSpot } from "../shared/spot-tour";
import {
  clampPitch,
  floorHit,
  lookDirection,
  nearbySpots,
  overviewBounds,
  pickSpot,
  type Vec3,
} from "./spot-viewer-math";
import { parsePly } from "./ply";
import {
  firstSpot,
  panoramaOrder,
  panoramaUrl,
  viewerModes,
  type ViewerMode,
} from "./spot-viewer-state";

const SPHERE_RADIUS = 50;
const MOVE_MS = 600;
const FADE_MS = 220;
const HINT = "Drag to look around. Tap a circle on the floor to move there.";

/** A sphere whose texture coordinates follow the panoramas' equirect convention exactly. */
function panoramaSphere(device: pc.GraphicsDevice) {
  const rows = 48,
    cols = 96,
    positions: number[] = [],
    uvs: number[] = [],
    indices: number[] = [];
  for (let r = 0; r <= rows; r++) {
    const pitch = Math.PI / 2 - (r / rows) * Math.PI;
    for (let c = 0; c <= cols; c++) {
      const yaw = (c / cols) * 2 * Math.PI - Math.PI;
      const d = lookDirection(yaw, pitch);
      positions.push(d[0] * SPHERE_RADIUS, d[1] * SPHERE_RADIUS, d[2] * SPHERE_RADIUS);
      // Panoramas upload as ImageBitmaps, which are not flipped: texture v = 0 is the top row.
      uvs.push(c / cols, r / rows);
    }
  }
  for (let r = 0; r < rows; r++)
    for (let c = 0; c < cols; c++) {
      const a = r * (cols + 1) + c,
        b = a + cols + 1;
      indices.push(a, a + 1, b, a + 1, b + 1, b);
    }
  const mesh = new pc.Mesh(device);
  mesh.setPositions(positions);
  mesh.setUvs(0, uvs);
  mesh.setIndices(indices);
  mesh.update();
  return mesh;
}

function unlitMaterial(texture?: pc.Texture) {
  const material = new pc.StandardMaterial();
  material.useLighting = false;
  material.diffuse = new pc.Color(0, 0, 0);
  material.emissive = new pc.Color(1, 1, 1);
  if (texture) material.emissiveMap = texture;
  material.cull = pc.CULLFACE_NONE;
  material.blendType = pc.BLEND_NORMAL;
  material.depthWrite = false;
  material.update();
  return material;
}

export default function SpotViewer({ tour }: { tour: RoomTour }) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const control = useRef<{
    go: (spot: TourSpot) => void;
    mode: (mode: ViewerMode) => void;
  }>({ go: () => {}, mode: () => {} });
  const result = tour.result as SpotTourResult | null;
  const spots = result && "spots" in result ? result.spots : [];
  const [mode, setMode] = useState<ViewerMode>("Walk");
  const [current, setCurrent] = useState<number | null>(firstSpot(spots)?.spot ?? null);
  const [message, setMessage] = useState("Loading tour…");
  const [hint, setHint] = useState(true);
  const [markers, setMarkers] = useState<{ spot: number; x: number; y: number }[]>([]);
  const [hasMesh, setHasMesh] = useState(false);

  useEffect(() => {
    const surface = canvas.current!;
    const start = firstSpot(spots);
    if (!start) {
      setMessage("This tour has no spots.");
      return;
    }
    const abort = new AbortController();
    const listeners = new AbortController();
    let disposed = false;
    const app = new pc.Application(surface, {
      graphicsDeviceOptions: { antialias: true, alpha: false },
    });
    app.setCanvasFillMode(pc.FILLMODE_NONE, surface.clientWidth, surface.clientHeight);
    app.setCanvasResolution(pc.RESOLUTION_AUTO);
    app.start();
    // Panoramas get their own layer, drawn just before the world's transparent pass: the floor
    // circles (and the mesh during a move) then always draw over the sphere around the camera.
    const world = app.scene.layers.getLayerByName("World")!;
    const panoramaLayer = new pc.Layer({ name: "Panorama", transparentSortMode: pc.SORTMODE_NONE });
    app.scene.layers.insertTransparent(
      panoramaLayer,
      app.scene.layers.getTransparentIndex(world),
    );
    const camera = new pc.Entity("Camera");
    camera.addComponent("camera", {
      layers: [world.id, panoramaLayer.id],
      clearColor: new pc.Color(0.08, 0.08, 0.09),
      nearClip: 0.05,
      farClip: 200,
      fov: 75,
    });
    app.root.addChild(camera);
    const sphereMesh = panoramaSphere(app.graphicsDevice);
    const makeSphere = () => {
      const material = unlitMaterial();
      const entity = new pc.Entity("Panorama");
      entity.addComponent("render", {
        meshInstances: [new pc.MeshInstance(sphereMesh, material)],
        layers: [panoramaLayer.id],
      });
      entity.enabled = false;
      app.root.addChild(entity);
      return { entity, material };
    };
    // Two spheres, so moving can fade one panorama into the next.
    const spheres = [makeSphere(), makeSphere()];
    let front = 0;
    const ringMaterial = unlitMaterial();
    ringMaterial.opacity = 0.85;
    ringMaterial.depthWrite = false;
    ringMaterial.update();
    const fillMaterial = unlitMaterial();
    fillMaterial.opacity = 0.22;
    fillMaterial.update();
    // A thin white ring with a faint fill, lying on the floor (radius ≈ the pick radius).
    const ringMesh = pc.Mesh.fromGeometry(
      app.graphicsDevice,
      new pc.TorusGeometry({ ringRadius: 0.3, tubeRadius: 0.018, segments: 48, sides: 8 }),
    );
    const fillMesh = pc.Mesh.fromGeometry(
      app.graphicsDevice,
      new pc.CylinderGeometry({ radius: 0.29, height: 0.002, capSegments: 48 }),
    );
    const rings = new Map<number, pc.Entity>();
    for (const s of spots) {
      const ring = new pc.Entity(`Spot ${s.spot}`);
      ring.addComponent("render", {
        meshInstances: [
          new pc.MeshInstance(fillMesh, fillMaterial),
          new pc.MeshInstance(ringMesh, ringMaterial),
        ],
      });
      ring.setPosition(s.position[0], s.floorY + 0.01, s.position[2]);
      ring.enabled = false;
      app.root.addChild(ring);
      rings.set(s.spot, ring);
    }
    let room: pc.Entity | null = null;
    const textures = new Map<number, Promise<pc.Texture>>();
    const load = (s: TourSpot) => {
      let texture = textures.get(s.spot);
      if (!texture) {
        texture = (async () => {
          const response = await fetch(panoramaUrl(tour.listingId, tour.id, s.spot), {
            credentials: "same-origin",
            signal: abort.signal,
          });
          if (!response.ok) throw new Error("unavailable");
          const bitmap = await createImageBitmap(await response.blob());
          const t = new pc.Texture(app.graphicsDevice, {
            width: bitmap.width,
            height: bitmap.height,
            format: pc.PIXELFORMAT_RGBA8,
            mipmaps: true,
            addressU: pc.ADDRESS_REPEAT,
            addressV: pc.ADDRESS_CLAMP_TO_EDGE,
          });
          t.setSource(bitmap as unknown as HTMLImageElement);
          return t;
        })();
        textures.set(s.spot, texture);
        texture.catch(() => textures.delete(s.spot));
      }
      return texture;
    };

    let yaw = 0,
      pitch = 0,
      here = start,
      viewMode: ViewerMode = "Walk",
      orbit = 0,
      moving = false;
    const bounds = overviewBounds(spots, tour.mesh);
    const eye = (s: TourSpot): Vec3 => [s.position[0], s.position[1], s.position[2]];
    const look = () => camera.setEulerAngles((pitch * 180) / Math.PI, (-yaw * 180) / Math.PI, 0);
    const showRings = () => {
      const near = new Set(nearbySpots(here, spots).map((s) => s.spot));
      for (const [n, ring] of rings) ring.enabled = viewMode === "Walk" && near.has(n);
    };
    const setOpacity = (index: number, value: number) => {
      spheres[index].material.opacity = value;
      spheres[index].material.update();
      spheres[index].entity.enabled = value > 0.001;
    };
    const place = (s: TourSpot) => {
      for (const sphere of spheres) sphere.entity.setPosition(...eye(s));
      camera.setPosition(...eye(s));
    };
    const show = async (s: TourSpot, fade: boolean) => {
      const back = 1 - front;
      try {
        const texture = await load(s);
        if (disposed) return;
        spheres[back].material.emissiveMap = texture;
        spheres[back].material.update();
        setMessage("");
      } catch {
        if (!disposed) setMessage("This spot couldn't load. Try another spot.");
        return;
      }
      const started = performance.now();
      const step = () => {
        const t = fade ? Math.min(1, (performance.now() - started) / FADE_MS) : 1;
        setOpacity(back, t);
        setOpacity(front, viewMode === "Walk" && !fade ? 0 : 1 - t);
        if (t < 1 && !disposed) requestAnimationFrame(step);
        else {
          setOpacity(front, 0);
          front = back;
        }
      };
      step();
      for (const next of panoramaOrder(s, spots).slice(1)) void load(next).catch(() => {});
    };
    const go = (target: TourSpot) => {
      if (moving || target.spot === here.spot) {
        if (viewMode !== "Walk") control.current.mode("Walk");
        return;
      }
      const from = eye(here);
      const to = eye(target);
      here = target;
      setCurrent(target.spot);
      setHint(false);
      if (viewMode !== "Walk") {
        viewMode = "Walk";
        setMode("Walk");
        applyMode();
      }
      showRings();
      moving = true;
      const started = performance.now();
      if (room) room.enabled = true;
      setOpacity(front, room ? 0 : 1);
      const step = () => {
        const t = Math.min(1, (performance.now() - started) / (room ? MOVE_MS : 1));
        const k = t * t * (3 - 2 * t);
        camera.setPosition(
          from[0] + (to[0] - from[0]) * k,
          from[1] + (to[1] - from[1]) * k,
          from[2] + (to[2] - from[2]) * k,
        );
        if (t < 1 && !disposed) {
          requestAnimationFrame(step);
          return;
        }
        place(target);
        if (room) room.enabled = false;
        moving = false;
        void show(target, true);
      };
      step();
    };
    const applyMode = () => {
      const cam = camera.camera!;
      showRings();
      if (viewMode === "Walk") {
        cam.projection = pc.PROJECTION_PERSPECTIVE;
        place(here);
        look();
        if (room) room.enabled = false;
        setOpacity(front, 1);
        return;
      }
      for (const sphere of spheres) sphere.entity.enabled = false;
      if (room) room.enabled = true;
      const [cx, cy, cz] = bounds.center;
      if (viewMode === "Plan") {
        cam.projection = pc.PROJECTION_ORTHOGRAPHIC;
        cam.orthoHeight = bounds.size * 0.6;
        camera.setPosition(cx, cy + 30, cz);
        camera.setEulerAngles(-90, 0, 0);
      } else {
        cam.projection = pc.PROJECTION_PERSPECTIVE;
        const distance = bounds.size * 1.3;
        camera.setPosition(
          cx + Math.sin(orbit) * distance * Math.cos(Math.PI / 4),
          cy + distance * Math.sin(Math.PI / 4),
          cz + Math.cos(orbit) * distance * Math.cos(Math.PI / 4),
        );
        camera.lookAt(new pc.Vec3(cx, cy, cz));
      }
    };
    control.current = {
      go,
      mode: (next) => {
        viewMode = next;
        setMode(next);
        applyMode();
      },
    };
    app.on("update", () => {
      if (viewMode === "Walk") {
        setMarkers((m) => (m.length ? [] : m));
        return;
      }
      const cam = camera.camera!;
      const width = surface.clientWidth,
        height = surface.clientHeight;
      setMarkers(
        spots.map((s) => {
          const p = cam.worldToScreen(new pc.Vec3(s.position[0], s.floorY, s.position[2]));
          void width;
          void height;
          return { spot: s.spot, x: p.x, y: p.y };
        }),
      );
    });

    let pointer: number | undefined,
      lastX = 0,
      lastY = 0,
      travelled = 0;
    surface.addEventListener(
      "pointerdown",
      (e) => {
        pointer = e.pointerId;
        lastX = e.clientX;
        lastY = e.clientY;
        travelled = 0;
        surface.setPointerCapture(e.pointerId);
      },
      { signal: listeners.signal },
    );
    surface.addEventListener(
      "pointermove",
      (e) => {
        if (e.pointerId !== pointer) return;
        const dx = e.clientX - lastX,
          dy = e.clientY - lastY;
        travelled += Math.abs(dx) + Math.abs(dy);
        lastX = e.clientX;
        lastY = e.clientY;
        if (viewMode === "Walk") {
          const scale = ((camera.camera!.fov * Math.PI) / 180) / surface.clientHeight;
          yaw -= dx * scale;
          pitch = clampPitch(pitch + dy * scale);
          look();
          if (travelled > 30) setHint(false);
        } else if (viewMode === "3D") {
          orbit -= dx * 0.01;
          applyMode();
        }
      },
      { signal: listeners.signal },
    );
    surface.addEventListener(
      "pointerup",
      (e) => {
        if (e.pointerId !== pointer) return;
        pointer = undefined;
        if (travelled > 8 || viewMode !== "Walk" || moving) return;
        const rect = surface.getBoundingClientRect();
        const cam = camera.camera!;
        const near = cam.screenToWorld(e.clientX - rect.left, e.clientY - rect.top, cam.nearClip);
        const far = cam.screenToWorld(e.clientX - rect.left, e.clientY - rect.top, 10);
        const dir: Vec3 = [far.x - near.x, far.y - near.y, far.z - near.z];
        const length = Math.hypot(...dir);
        const hit = floorHit(eye(here), [dir[0] / length, dir[1] / length, dir[2] / length], here.floorY);
        const target = hit && pickSpot(hit, nearbySpots(here, spots));
        if (target) go(target);
      },
      { signal: listeners.signal },
    );
    surface.addEventListener("pointercancel", () => (pointer = undefined), {
      signal: listeners.signal,
    });
    surface.addEventListener(
      "keydown",
      (e) => {
        const turn = (Math.PI / 180) * 10;
        if (e.key === "ArrowLeft") yaw -= turn;
        else if (e.key === "ArrowRight") yaw += turn;
        else if (e.key === "ArrowUp") pitch = clampPitch(pitch + turn);
        else if (e.key === "ArrowDown") pitch = clampPitch(pitch - turn);
        else return;
        e.preventDefault();
        if (viewMode === "Walk") look();
      },
      { signal: listeners.signal },
    );
    const resizeCanvas = () =>
      app.resizeCanvas(surface.parentElement!.clientWidth, Math.min(innerHeight * 0.7, 560));
    const resize = new ResizeObserver(resizeCanvas);
    resize.observe(surface.parentElement!);
    resizeCanvas();

    place(start);
    look();
    showRings();
    void show(start, false);
    if (tour.mesh)
      void (async () => {
        try {
          const response = await fetch(
            `/api/listings/${encodeURIComponent(tour.listingId)}/tours/${encodeURIComponent(tour.id)}/mesh`,
            { credentials: "same-origin", signal: abort.signal },
          );
          if (!response.ok) return;
          const parsed = parsePly(await response.arrayBuffer());
          if (disposed) return;
          const mesh = new pc.Mesh(app.graphicsDevice);
          mesh.setPositions(parsed.positions);
          mesh.setColors32(parsed.colors);
          mesh.setIndices(parsed.indices);
          mesh.update();
          const material = new pc.StandardMaterial();
          material.useLighting = false;
          material.diffuse = new pc.Color(0, 0, 0);
          material.emissive = new pc.Color(1, 1, 1);
          material.emissiveVertexColor = true;
          material.cull = pc.CULLFACE_NONE;
          material.update();
          room = new pc.Entity("Room");
          room.addComponent("render", { meshInstances: [new pc.MeshInstance(mesh, material)] });
          room.enabled = viewMode !== "Walk";
          app.root.addChild(room);
          setHasMesh(true);
        } catch {
          /* The overview falls back to spot markers. */
        }
      })();
    return () => {
      disposed = true;
      abort.abort();
      listeners.abort();
      resize.disconnect();
      control.current = { go: () => {}, mode: () => {} };
      app.destroy();
    };
    // spots derive from tour.result
  }, [tour.id, tour.listingId, tour.result, tour.mesh]);

  const modes = viewerModes(hasMesh);
  return (
    <div className="spot-viewer">
      <div className="spot-viewer-stage">
        <canvas
          ref={canvas}
          tabIndex={0}
          aria-label="360° photo at a capture spot. Drag or use arrow keys to look around; tap a floor circle to move."
        />
        {mode !== "Walk" &&
          markers.map((m) => (
            <button
              key={m.spot}
              className={"spot-marker" + (m.spot === current ? " current" : "")}
              style={{ left: m.x, top: m.y }}
              onClick={() => {
                const s = spots.find((x) => x.spot === m.spot);
                if (s) control.current.go(s);
              }}
              aria-label={`Spot ${m.spot}`}
            >
              {m.spot}
            </button>
          ))}
        {hint && mode === "Walk" && <p className="spot-hint">{HINT}</p>}
        <div className="spot-modes" role="group" aria-label="View">
          {modes.map((m) => (
            <button
              key={m}
              aria-pressed={mode === m}
              onClick={() => control.current.mode(m)}
            >
              {m}
            </button>
          ))}
        </div>
      </div>
      <p role="status">{message}</p>
      <nav className="spot-list" aria-label="Spots">
        {spots
          .slice()
          .sort((a, b) => a.spot - b.spot)
          .map((s) => (
            <button
              key={s.spot}
              aria-current={s.spot === current ? "true" : undefined}
              onClick={() => control.current.go(s)}
            >
              Spot {s.spot}
            </button>
          ))}
      </nav>
    </div>
  );
}
