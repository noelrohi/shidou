'use strict';

(() => {
  const host = document.getElementById('diagram');
  let sequence = 0;

  window.renderMermaid = async (source, appearance) => {
    host.replaceChildren();
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: 'strict',
      suppressErrorRendering: true,
      logLevel: 'fatal',
      theme: appearance === 'dark' ? 'dark' : 'default',
      deterministicIds: true,
      deterministicIDSeed: 'shidou-ios',
      maxTextSize: 50000,
      maxEdges: 500,
      fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif',
      flowchart: { htmlLabels: false, useMaxWidth: true }
    });

    try {
      const result = await mermaid.render(`shidou-mermaid-${++sequence}`, source);
      host.innerHTML = result.svg;
      const svg = host.querySelector('svg');
      if (!svg) throw new Error('Mermaid returned no SVG');
      svg.removeAttribute('height');
      svg.setAttribute('width', '100%');
      await new Promise(resolve => requestAnimationFrame(resolve));
      const height = Math.ceil(Math.max(svg.getBoundingClientRect().height, host.scrollHeight));
      if (!Number.isFinite(height) || height <= 0) throw new Error('Invalid diagram size');
      return { height };
    } catch (error) {
      host.replaceChildren();
      throw error;
    }
  };
})();
