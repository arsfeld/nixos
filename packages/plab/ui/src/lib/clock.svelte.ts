const secs = () => Math.floor(Date.now() / 1000);

/** Server time, ticking each second: job cards count against it, not the client's clock. */
class Clock {
  private offset = 0;
  now = $state(secs());

  constructor() {
    setInterval(() => {
      this.now = secs() + this.offset;
    }, 1000);
  }

  sync(server: number) {
    this.offset = server - secs();
    this.now = server;
  }
}

export const clock = new Clock();
