import { useEffect, useRef, useState } from "react";
import * as pc from "playcanvas";
import type { RoomTour } from "../shared/room-tour";
export default function SplatViewer({ tour }: { tour: RoomTour }) {
  const canvas = useRef<HTMLCanvasElement>(null),
    commands = useRef<(action: string) => void>(() => {}),
    [message, setMessage] = useState("Loading reconstruction…");
  useEffect(() => {
    const surface = canvas.current!;
    const abort = new AbortController();
    let disposed = false,
      app: pc.Application | undefined,
      asset: pc.Asset | undefined,
      blobURL: string | undefined,
      resize: ResizeObserver | undefined;
    const listeners = new AbortController();
    async function load() {
      try {
        if (!tour.result) throw new Error("Missing tour camera");
        const response = await fetch(
          `/api/listings/${tour.listingId}/tours/${tour.id}/model`,
          { credentials: "same-origin", signal: abort.signal },
        );
        if (!response.ok)
          throw new Error("Tour unavailable. Reload or sign in again.");
        const blob = await response.blob();
        if (disposed) return;
        blobURL = URL.createObjectURL(blob);
        app = new pc.Application(surface, {
          graphicsDeviceOptions: { antialias: false, alpha: false },
        });
        app.setCanvasFillMode(
          pc.FILLMODE_NONE,
          surface.clientWidth,
          surface.clientHeight,
        );
        app.setCanvasResolution(pc.RESOLUTION_AUTO);
        app.start();
        const camera = new pc.Entity("Camera");
        camera.addComponent("camera", {
          clearColor: new pc.Color(0.12, 0.12, 0.12),
          nearClip: 0.01,
          farClip: 200,
        });
        app.root.addChild(camera);
        const original = tour.result.camera;
        let yaw = 0,
          pitch = 0;
        const reset = () => {
          camera.setPosition(
            ...(original.position as [number, number, number]),
          );
          camera.lookAt(
            new pc.Vec3(...(original.target as [number, number, number])),
            new pc.Vec3(...(original.up as [number, number, number])),
          );
          const e = camera.getEulerAngles();
          yaw = e.y;
          pitch = e.x;
        };
        reset();
        commands.current = (action) => {
          if (action === "reset") reset();
          else if (action === "left")
            camera.translate(camera.right.clone().mulScalar(-0.2));
          else if (action === "right")
            camera.translate(camera.right.clone().mulScalar(0.2));
          else
            camera.translate(
              camera.forward
                .clone()
                .mulScalar(action === "forward" ? 0.2 : -0.2),
            );
        };
        let pointer: number | undefined,
          lastX = 0,
          lastY = 0;
        surface.addEventListener(
          "pointerdown",
          (e) => {
            pointer = e.pointerId;
            lastX = e.clientX;
            lastY = e.clientY;
            surface.setPointerCapture(e.pointerId);
            surface.focus();
          },
          { signal: listeners.signal },
        );
        surface.addEventListener(
          "pointerup",
          () => {
            pointer = undefined;
          },
          { signal: listeners.signal },
        );
        surface.addEventListener(
          "pointercancel",
          () => {
            pointer = undefined;
          },
          { signal: listeners.signal },
        );
        surface.addEventListener(
          "pointermove",
          (e) => {
            if (e.pointerId !== pointer) return;
            yaw -= (e.clientX - lastX) * 0.2;
            pitch = Math.max(
              -85,
              Math.min(85, pitch - (e.clientY - lastY) * 0.2),
            );
            lastX = e.clientX;
            lastY = e.clientY;
            camera.setEulerAngles(pitch, yaw, 0);
          },
          { signal: listeners.signal },
        );
        surface.addEventListener(
          "keydown",
          (e) => {
            const actions: Record<string, string> = {
              ArrowUp: "forward",
              ArrowDown: "back",
              ArrowLeft: "left",
              ArrowRight: "right",
              r: "reset",
            };
            if (actions[e.key]) {
              e.preventDefault();
              commands.current(actions[e.key]);
            }
          },
          { signal: listeners.signal },
        );
        const resizeCanvas = () =>
          app?.resizeCanvas(
            surface.parentElement!.clientWidth,
            Math.min(innerHeight * 0.65, 520),
          );
        resize = new ResizeObserver(resizeCanvas);
        resize.observe(surface.parentElement!);
        window.addEventListener("resize", resizeCanvas, {
          signal: listeners.signal,
        });
        resizeCanvas();
        asset = new pc.Asset("Room", "gsplat", {
          url: blobURL,
          filename: "room.ply",
        });
        asset.on("error", () => {
          if (!disposed)
            setMessage(
              "This reconstruction could not be rendered on this device. Try another browser or export the PLY.",
            );
        });
        asset.ready(() => {
          if (disposed || !app || !asset) return;
          const room = new pc.Entity("Room");
          room.addComponent("gsplat", { asset });
          app.root.addChild(room);
          setMessage(
            "Drag to look. Use the controls or arrow keys to move. Movement has no wall collisions.",
          );
          if (blobURL) {
            URL.revokeObjectURL(blobURL);
            blobURL = undefined;
          }
        });
        app.assets.add(asset);
        app.assets.load(asset);
      } catch (e) {
        if (!disposed) setMessage((e as Error).message);
      }
    }
    void load();
    return () => {
      disposed = true;
      abort.abort();
      listeners.abort();
      resize?.disconnect();
      commands.current = () => {};
      asset?.unload();
      app?.destroy();
      if (blobURL) URL.revokeObjectURL(blobURL);
    };
  }, [tour.id, tour.listingId, tour.result]);
  return (
    <div>
      <canvas
        ref={canvas}
        tabIndex={0}
        aria-label="Photographic room reconstruction. Drag to look, arrow keys to move, R to reset."
        style={{
          width: "100%",
          height: "min(65vh,520px)",
          display: "block",
          touchAction: "none",
          borderRadius: 12,
        }}
      />
      <p role="status">{message}</p>
      <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
        {[
          ["left", "Left"],
          ["forward", "Forward"],
          ["back", "Back"],
          ["right", "Right"],
          ["reset", "Reset view"],
        ].map(([action, label]) => (
          <button key={action} onClick={() => commands.current(action)}>
            {label}
          </button>
        ))}
      </div>
    </div>
  );
}
