import React from "react";
import { createRoot } from "react-dom/client";
import { NativeTourPage } from "./RoomTours";
import App from "./App";
import "./styles.css";
import "./community.css";
import "leaflet/dist/leaflet.css";
createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    {location.pathname === "/tour-viewer" ? <NativeTourPage /> : <App />}
  </React.StrictMode>,
);
