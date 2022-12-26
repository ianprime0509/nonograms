import { LitElement, css, html } from "lit";
import { customElement, property, state, query } from "lit/decorators.js";
import { drawCell } from "./drawing.js";
import { Color, Puzzle } from "./puzzle.js";
import { ResizeController } from "./resize-controller.js";

export type Position = [number, number];

@customElement("ng-grid")
export class Grid extends LitElement {
  static override styles = css`
    #container {
      display: flex;
      align-items: center;
      justify-content: center;
      height: 100%;
      width: 100%;
    }
  `;
  private static padding = 5;

  @property({ type: Object }) puzzle: Puzzle = {
    rowClues: [],
    columnClues: [],
    state: [],
  };
  @query("canvas") private canvas!: HTMLCanvasElement;
  @state() private height = 0;
  @state() private width = 0;
  private rows = 0;
  private columns = 0;
  private maxRowClues = 0;
  private maxColumnClues = 0;
  private cellSize = 0;
  @state() private hoverCell: Position | null = null;

  constructor() {
    super();
    new ResizeController(this, this.handleResize.bind(this));
  }

  protected override render() {
    return html`
      <div id="container">
        <canvas
          height=${this.height}
          width=${this.width}
          @mousedown=${this.handleMouseDown}
          @mouseleave=${this.handleMouseLeave}
          @mousemove=${this.handleMouseMove}
        ></canvas>
      </div>
    `;
  }

  protected override willUpdate() {
    this.rows = this.puzzle.state.length;
    this.columns = this.puzzle.state[0].length;
    this.maxRowClues = Math.max(
      ...this.puzzle.rowClues.map((clues) => clues.length)
    );
    this.maxColumnClues = Math.max(
      ...this.puzzle.columnClues.map((clues) => clues.length)
    );
    // height = 2 * padding + (maxRowClues / 2) * cellSize + rows * cellSize
    // width = 2 * padding + (maxColumnClues / 2) * cellSize + columns * cellSize
    this.cellSize = Math.min(
      (this.height - 2 * Grid.padding) / (this.rows + this.maxRowClues / 2),
      (this.width - 2 * Grid.padding) / (this.columns + this.maxColumnClues / 2)
    );
  }

  protected override updated() {
    this.draw();
  }

  setColor(row: number, column: number, color: Color | null) {
    if (
      row >= 0 &&
      row < this.rows &&
      column >= 0 &&
      column < this.columns &&
      color !== this.puzzle.state[row][column].color
    ) {
      this.puzzle.state[row][column].color = color;
      this.requestUpdate();
    }
  }

  private draw() {
    const ctx = this.canvas.getContext("2d");
    if (!ctx || this.height <= 0 || this.width <= 0) return;

    ctx.clearRect(0, 0, this.width, this.height);
    ctx.lineWidth = 1;
    ctx.strokeStyle = "black";
    ctx.font = `${this.fontSize}px sans-serif`;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    // Hover clues
    if (this.hoverCell) {
      ctx.fillStyle = "lightgrey";
      ctx.fillRect(
        Grid.padding,
        Grid.padding + this.columnCluesSize + this.hoverCell[0] * this.cellSize,
        this.rowCluesSize,
        this.cellSize
      );
      ctx.fillRect(
        Grid.padding + this.rowCluesSize + this.hoverCell[1] * this.cellSize,
        Grid.padding,
        this.cellSize,
        this.columnCluesSize
      );
    }
    // Clues and grid
    for (let j = 0; j < this.columns; j++) {
      this.puzzle.columnClues[j].forEach((clue, n) => {
        const [x, y] = this.columnCluePosition(j, n);
        ctx.fillStyle = clue.color;
        ctx.fillText(clue.n.toString(), x, y);
      });
    }
    for (let i = 0; i < this.rows; i++) {
      this.puzzle.rowClues[i].forEach((clue, n) => {
        const [x, y] = this.rowCluePosition(i, n);
        ctx.fillStyle = clue.color;
        ctx.fillText(clue.n.toString(), x, y);
      });
      for (let j = 0; j < this.columns; j++) {
        const [x, y] = this.cellPosition(i, j);
        const color = this.puzzle.state[i][j].color;
        drawCell(ctx, color, x, y, this.cellSize);
      }
    }
    // Additional separators
    ctx.lineWidth = 3;
    for (let j = 0; j <= this.columns; j += 5) {
      const [x, y] = this.cellPosition(this.rows - 1, j);
      ctx.beginPath();
      ctx.moveTo(x, Grid.padding);
      ctx.lineTo(x, y + this.cellSize);
      ctx.stroke();
    }
    for (let i = 0; i <= this.columns; i += 5) {
      const [x, y] = this.cellPosition(i, this.columns - 1);
      ctx.beginPath();
      ctx.moveTo(Grid.padding, y);
      ctx.lineTo(x + this.cellSize, y);
      ctx.stroke();
    }
    // Hover cell
    if (this.hoverCell) {
      ctx.strokeStyle = "blue";
      ctx.lineWidth = 4;
      const [x, y] = this.cellPosition(...this.hoverCell);
      ctx.strokeRect(x, y, this.cellSize, this.cellSize);
    }
  }

  private get clueSize() {
    return this.cellSize / 2;
  }

  private get rowCluesSize() {
    return this.clueSize * this.maxRowClues;
  }

  private get columnCluesSize() {
    return this.clueSize * this.maxColumnClues;
  }

  private get fontSize() {
    return this.cellSize / 2;
  }

  private handleMouseDown(e: MouseEvent) {
    const bounds = this.canvas.getBoundingClientRect();
    const cell = this.cellAt(e.clientX - bounds.left, e.clientY - bounds.top);
    if (cell && e.button === 0) {
      this.dispatchEvent(new CellSelectEvent(...cell));
    }
  }

  private handleMouseLeave() {
    this.hoverCell = null;
  }

  private handleMouseMove(e: MouseEvent) {
    const bounds = this.canvas.getBoundingClientRect();
    const cell = this.cellAt(e.clientX - bounds.left, e.clientY - bounds.top);
    if (cell && e.buttons & 1) {
      this.dispatchEvent(new CellSelectEvent(...cell));
    }
    this.hoverCell = cell;
  }

  private handleResize(newHeight: number, newWidth: number) {
    this.height = this.width = Math.min(newHeight, newWidth);
  }

  private columnCluePosition(column: number, n: number) {
    const clueOffset =
      this.maxColumnClues - this.puzzle.columnClues[column].length;
    return [
      Grid.padding + this.rowCluesSize + (column + 0.5) * this.cellSize,
      Grid.padding + (clueOffset + n + 0.5) * this.clueSize,
    ];
  }

  private rowCluePosition(row: number, n: number) {
    const clueOffset = this.maxRowClues - this.puzzle.rowClues[row].length;
    return [
      Grid.padding + (clueOffset + n + 0.5) * this.clueSize,
      Grid.padding + this.columnCluesSize + (row + 0.5) * this.cellSize,
    ];
  }

  private cellAt(x: number, y: number): Position | null {
    const [i, j] = [
      Math.floor((y - Grid.padding - this.columnCluesSize) / this.cellSize),
      Math.floor((x - Grid.padding - this.rowCluesSize) / this.cellSize),
    ];
    return i >= 0 && i < this.rows && j >= 0 && j < this.columns
      ? [i, j]
      : null;
  }

  private cellPosition(row: number, column: number) {
    return [
      Grid.padding + this.rowCluesSize + column * this.cellSize,
      Grid.padding + this.columnCluesSize + row * this.cellSize,
    ];
  }
}

export class CellSelectEvent extends Event {
  constructor(public row: number, public column: number) {
    super("cell-select", { composed: true });
  }
}

declare global {
  interface HTMLElementTagNameMap {
    "ng-grid": Grid;
  }
}
