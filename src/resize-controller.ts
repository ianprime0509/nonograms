import { ReactiveController, ReactiveControllerHost } from "lit";

export type HandleResizeFunc = (newHeight: number, newWidth: number) => void;

export class ResizeController implements ReactiveController {
  #host: ReactiveControllerHost & Element;
  #handleResize: HandleResizeFunc;
  #observer: ResizeObserver | null = null;

  constructor(
    host: ReactiveControllerHost & Element,
    handleResize: HandleResizeFunc
  ) {
    (this.#host = host).addController(this);
    this.#handleResize = handleResize;
  }

  hostConnected() {
    this.#observer = new ResizeObserver((entries) => {
      const entry = entries.find((entry) => entry.target === this.#host);
      if (entry) {
        this.#handleResize(entry.contentRect.height, entry.contentRect.width);
      }
    });
    this.#observer.observe(this.#host);
  }

  hostDisconnected() {
    this.#observer?.disconnect();
    this.#observer = null;
  }
}
