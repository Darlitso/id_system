import "dotenv/config";
import app from "./app.js";

const PORT = process.env.PORT || 3000;

  app.get('/', (req, res) => res.json({ service: 'NIDS API', status: 'online' }));
app.listen(PORT, () => {
  console.log(`API running on http://localhost:${PORT}`);
});