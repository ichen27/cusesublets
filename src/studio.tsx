// The Tour Studio viewer page: one property's 360° tour, served by studio/server.py.
import React, { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import type { RoomTour } from "../shared/room-tour";
import SpotViewer from "./SpotViewer";
import "./styles.css";
import "./room-tours.css";

interface Property {
  name: string;
  status: "processing" | "ready" | "failed";
  error: string | null;
  tour: RoomTour | null;
}

function StudioTour() {
  const id = location.pathname.split("/").pop() ?? "";
  const [property, setProperty] = useState<Property | null>(null);
  const [problem, setProblem] = useState("");
  useEffect(() => {
    let stop = false;
    let timer = 0;
    const load = async () => {
      try {
        const response = await fetch(`/api/properties/${encodeURIComponent(id)}`);
        if (!response.ok) throw new Error("This property was not found.");
        const value = (await response.json()) as Property;
        if (stop) return;
        setProperty(value);
        if (value.status === "processing") timer = window.setTimeout(load, 2000);
      } catch (error) {
        if (!stop) setProblem(error instanceof Error ? error.message : "Could not load the tour.");
      }
    };
    void load();
    return () => {
      stop = true;
      window.clearTimeout(timer);
    };
  }, [id]);
  if (problem) return <p role="alert">{problem}</p>;
  if (!property) return <p role="status">Loading…</p>;
  if (property.status === "processing") return <p role="status">Stitching the tour…</p>;
  if (!property.tour)
    return <p role="alert">The tour could not be made ({property.error ?? "unknown error"}).</p>;
  return (
    <section className="room-tour">
      <h3>{property.name}</h3>
      <SpotViewer tour={property.tour} />
    </section>
  );
}

createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <StudioTour />
  </React.StrictMode>,
);
