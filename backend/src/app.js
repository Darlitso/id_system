
import express from "express";
import cors from "cors";
import helmet from "helmet";

const app = express();

app.use(helmet());

app.use(
  cors({
    origin: "http://localhost:5173",
  }),
);

app.use(express.json({ limit: "100kb" }));

app.get("/api/health", (req, res) => {
  res.json({
    status: "ok",
    message: "Proposed identity system API is running",
  });
});

export default app;
