/**
 * S3 Neo Super AMOLED Eyes Plugin for OpenVoiceUI
 * Renders pure #000000 background with glowing vector eyes and OLED pixel-shift protection.
 */
export default class S3NeoAmoledFacePlugin {
  constructor(container, audioAnalyser) {
    this.container = container;
    this.analyser = audioAnalyser;
    this.canvas = document.createElement('canvas');
    this.ctx = this.canvas.getContext('2d');
    this.container.style.backgroundColor = '#000000';
    this.container.appendChild(this.canvas);
    this.mood = 'neutral';
    this.resize();
    window.addEventListener('resize', () => this.resize());
  }

  resize() {
    this.canvas.width = this.container.clientWidth || window.innerWidth;
    this.canvas.height = this.container.clientHeight || window.innerHeight;
  }

  setMood(mood) {
    this.mood = mood;
  }
}
