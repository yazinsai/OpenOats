type PlayerCallback = (currentTime: number) => void;

export class YouTubePlayer {
  private player: YT.Player | null = null;
  private container: HTMLElement;
  private onTimeUpdate: PlayerCallback;
  private onSeek: PlayerCallback;
  private pollInterval: number | null = null;
  private lastReportedTime = -1;

  constructor(
    containerId: string,
    onTimeUpdate: PlayerCallback,
    onSeek: PlayerCallback
  ) {
    this.container = document.getElementById(containerId)!;
    this.onTimeUpdate = onTimeUpdate;
    this.onSeek = onSeek;
  }

  async loadVideo(videoId: string): Promise<void> {
    await this.ensureAPI();

    if (this.player) {
      this.player.destroy();
      this.stopPolling();
    }

    // Create a fresh div for the player
    const playerDiv = document.createElement("div");
    playerDiv.id = "yt-iframe";
    this.container.innerHTML = "";
    this.container.appendChild(playerDiv);

    return new Promise<void>((resolve) => {
      this.player = new YT.Player("yt-iframe", {
        videoId,
        width: "100%",
        height: "360",
        playerVars: { autoplay: 0, modestbranding: 1, rel: 0 },
        events: {
          onReady: () => {
            this.startPolling();
            resolve();
          },
          onStateChange: (event: YT.OnStateChangeEvent) => {
            if (event.data === YT.PlayerState.PLAYING) {
              this.startPolling();
            } else {
              this.stopPolling();
            }
          },
        },
      });
    });
  }

  getCurrentTime(): number {
    return this.player?.getCurrentTime() ?? 0;
  }

  seekTo(seconds: number): void {
    this.player?.seekTo(seconds, true);
    this.onSeek(seconds);
  }

  private startPolling(): void {
    this.stopPolling();
    this.pollInterval = window.setInterval(() => {
      const t = this.getCurrentTime();
      // Detect seek: jump of >2s since last poll
      if (
        this.lastReportedTime >= 0 &&
        Math.abs(t - this.lastReportedTime) > 2
      ) {
        this.onSeek(t);
      }
      this.lastReportedTime = t;
      this.onTimeUpdate(t);
    }, 1000);
  }

  private stopPolling(): void {
    if (this.pollInterval !== null) {
      clearInterval(this.pollInterval);
      this.pollInterval = null;
    }
  }

  private ensureAPI(): Promise<void> {
    if (window.YT && window.YT.Player) return Promise.resolve();
    return new Promise<void>((resolve) => {
      const script = document.createElement("script");
      script.src = "https://www.youtube.com/iframe_api";
      document.head.appendChild(script);
      (window as any).onYouTubeIframeAPIReady = () => resolve();
    });
  }
}

export function extractVideoId(url: string): string | null {
  const patterns = [
    /(?:youtube\.com\/watch\?v=|youtu\.be\/|youtube\.com\/embed\/)([a-zA-Z0-9_-]{11})/,
    /^([a-zA-Z0-9_-]{11})$/,
  ];
  for (const p of patterns) {
    const m = url.match(p);
    if (m) return m[1];
  }
  return null;
}
