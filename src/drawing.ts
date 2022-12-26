import { Color } from "./puzzle.js";

export function drawCell(
  ctx: CanvasRenderingContext2D,
  color: Color | null,
  x: number,
  y: number,
  size: number
) {
  ctx.fillStyle = color ?? "white";
  ctx.fillRect(x, y, size, size);
  ctx.strokeStyle = "black";
  ctx.strokeRect(x, y, size, size);
  if (color === null) {
    ctx.beginPath();
    ctx.moveTo(x + 0.25 * size, y + 0.25 * size);
    ctx.lineTo(x + 0.75 * size, y + 0.75 * size);
    ctx.moveTo(x + 0.25 * size, y + 0.75 * size);
    ctx.lineTo(x + 0.75 * size, y + 0.25 * size);
    ctx.stroke();
  }
}
