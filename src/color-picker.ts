import { LitElement, css, html } from "lit";
import { customElement, property, queryAll } from "lit/decorators.js";
import { drawCell } from "./drawing.js";
import { Color } from "./puzzle.js";

@customElement("ng-color-picker")
export class ColorPicker extends LitElement {
  static override styles = css`
    #container {
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 0.5rem;
    }

    canvas.selected {
      box-shadow: 0 0 10px blue;
    }
  `;

  @property({ type: Array }) colors: Color[] = [];
  @property() selectedColor: Color | null = null;
  @queryAll("canvas") canvases!: HTMLCanvasElement[];
  private tileSize = 40;

  protected override render() {
    return html`
      <div id="container">
        <canvas
          height=${this.tileSize}
          width=${this.tileSize}
          @click=${() => (this.selectedColor = null)}
        ></canvas>
        ${this.colors.map(
          (color) =>
            html`<canvas
              height=${this.tileSize}
              width=${this.tileSize}
              data-color=${color}
              @click=${() => (this.selectedColor = color)}
            ></canvas>`
        )}
      </div>
    `;
  }

  protected override updated() {
    this.draw();
  }

  private draw() {
    for (const canvas of this.canvases) {
      const color = canvas.getAttribute("data-color");
      const ctx = canvas.getContext("2d");
      if (!ctx) continue;
      ctx.clearRect(0, 0, this.tileSize, this.tileSize);
      drawCell(ctx, color, 0, 0, this.tileSize);
      if (color === this.selectedColor) {
        canvas.classList.add("selected");
      } else {
        canvas.classList.remove("selected");
      }
    }
  }
}

declare global {
  interface HTMLElementTagNameMap {
    "ng-color-picker": ColorPicker;
  }
}
