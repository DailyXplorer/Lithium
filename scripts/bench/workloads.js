(() => {
  const fixtures = {
    json() {
      const source = JSON.stringify(Array.from({length: 6000}, (_, i) => ({id: i, title: 'Article ' + i, tags: ['web', 'browser'], score: i % 91})));
      return () => {
        let checksum = 0;
        for (let i = 0; i < 15; i++) {
          const data = JSON.parse(source);
          data.sort((a, b) => b.score - a.score);
          checksum += JSON.stringify(data).length;
        }
        return checksum;
      };
    },
    dom() {
      return () => {
        const root = document.createElement('section');
        for (let i = 0; i < 2500; i++) {
          const row = document.createElement('div');
          const span = document.createElement('span');
          span.textContent = 'Article number ' + i;
          row.appendChild(span);
          root.appendChild(row);
        }
        document.body.appendChild(root);
        const checksum = root.offsetHeight + root.children.length;
        root.remove();
        return checksum;
      };
    },
    layout() {
      const root = document.createElement('section');
      root.innerHTML = Array.from({length: 1200}, (_, i) => `<div class="row">Article ${i}</div>`).join('');
      document.body.append(root);
      return () => {
        let checksum = 0;
        for (let i = 0; i < 12; i++) {
          root.className = i % 2 ? 'compact' : '';
          checksum += root.offsetHeight;
        }
        return checksum;
      };
    },
    canvas() {
      const canvas = document.createElement('canvas');
      canvas.width = canvas.height = 512;
      const ctx = canvas.getContext('2d', {willReadFrequently: true});
      ctx.fillStyle = '#5a7284';
      ctx.fillRect(0, 0, 512, 512);
      return () => {
        let checksum = 0;
        for (let i = 0; i < 8; i++) checksum += ctx.getImageData(0, 0, 512, 512).data.length;
        return checksum;
      };
    }
  };
  globalThis.perfCase = (name) => {
    document.body.innerHTML = '';
    const style = document.createElement('style');
    style.textContent = 'body { margin:0; font:16px Arial; } .row { padding:2px; } .compact .row { padding:1px; font-size:14px; }';
    document.head.append(style);
    const operation = fixtures[name]();
    operation();
    const samples = [];
    const checksums = [];
    for (let i = 0; i < 7; i++) {
      const start = performance.now();
      checksums.push(operation());
      samples.push(performance.now() - start);
    }
    style.remove();
    return {name, samples, checksums, visibility: document.visibilityState, userAgent: navigator.userAgent};
  };
})();
