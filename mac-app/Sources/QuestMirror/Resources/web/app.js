// Quest Mirror WebXR client.
//
// Flow: open a WebSocket back to the Mac that served this page, receive a
// WebRTC offer, answer it, and once the video track arrives, render it as a
// floating textured quad inside an immersive-vr WebXR session. No 3D engine
// dependency (Three.js etc.) on purpose, so this page works purely from the
// local network with no CDN/internet access required.

const statusEl = document.getElementById('status');
const previewEl = document.getElementById('preview');
const enterVRButton = document.getElementById('enterVR');
const canvas = document.getElementById('glcanvas');

let ws;
let pc;
let gl;
let xrSession = null;
let xrRefSpace = null;
let videoTexture = null;
let glProgram, glBuffers, glLocations;

function setStatus(text) {
  statusEl.textContent = text;
}

// ---------------------------------------------------------------------
// Signaling (WebSocket to the Mac app)
// ---------------------------------------------------------------------

function connectSignaling() {
  const url = `ws://${location.host}/ws`;
  ws = new WebSocket(url);

  ws.onopen = () => setStatus('Connected. Waiting for video from Mac…');
  ws.onclose = () => setStatus('Disconnected from Mac. Reload to retry.');
  ws.onerror = () => setStatus('Connection error. Reload to retry.');

  ws.onmessage = async (event) => {
    const message = JSON.parse(event.data);
    if (message.type === 'offer') {
      await handleOffer(message.sdp);
    } else if (message.type === 'ice') {
      if (pc && message.candidate) {
        try {
          await pc.addIceCandidate({
            candidate: message.candidate,
            sdpMid: message.sdpMid,
            sdpMLineIndex: message.sdpMLineIndex,
          });
        } catch (err) {
          console.warn('Failed to add ICE candidate', err);
        }
      }
    }
  };
}

function send(message) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(message));
  }
}

async function handleOffer(sdp) {
  pc = new RTCPeerConnection({
    iceServers: [{ urls: 'stun:stun.l.google.com:19302' }],
  });

  pc.onicecandidate = (event) => {
    if (event.candidate) {
      send({
        type: 'ice',
        candidate: event.candidate.candidate,
        sdpMid: event.candidate.sdpMid,
        sdpMLineIndex: event.candidate.sdpMLineIndex,
      });
    }
  };

  pc.ontrack = (event) => {
    previewEl.srcObject = event.streams[0];
    setStatus('Receiving Mac screen. Put on your headset and tap Enter VR.');
    enterVRButton.disabled = false;
  };

  await pc.setRemoteDescription({ type: 'offer', sdp });
  const answer = await pc.createAnswer();
  await pc.setLocalDescription(answer);
  send({ type: 'answer', sdp: answer.sdp });
}

// ---------------------------------------------------------------------
// WebXR + WebGL rendering of the video as a floating panel
// ---------------------------------------------------------------------

function initGL() {
  gl = canvas.getContext('webgl', { xrCompatible: true });

  const vsSource = `
    attribute vec2 aPosition;
    attribute vec2 aTexCoord;
    uniform mat4 uModelViewProjection;
    varying vec2 vTexCoord;
    void main() {
      gl_Position = uModelViewProjection * vec4(aPosition, 0.0, 1.0);
      vTexCoord = aTexCoord;
    }
  `;
  const fsSource = `
    precision mediump float;
    varying vec2 vTexCoord;
    uniform sampler2D uVideoTexture;
    void main() {
      gl_FragColor = texture2D(uVideoTexture, vTexCoord);
    }
  `;

  function compile(type, source) {
    const shader = gl.createShader(type);
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
      console.error(gl.getShaderInfoLog(shader));
    }
    return shader;
  }

  glProgram = gl.createProgram();
  gl.attachShader(glProgram, compile(gl.VERTEX_SHADER, vsSource));
  gl.attachShader(glProgram, compile(gl.FRAGMENT_SHADER, fsSource));
  gl.linkProgram(glProgram);

  glLocations = {
    position: gl.getAttribLocation(glProgram, 'aPosition'),
    texCoord: gl.getAttribLocation(glProgram, 'aTexCoord'),
    mvp: gl.getUniformLocation(glProgram, 'uModelViewProjection'),
    videoTexture: gl.getUniformLocation(glProgram, 'uVideoTexture'),
  };

  // A 16:9 panel, ~1.6m wide, centered in front of the viewer.
  const halfW = 0.8, halfH = 0.45;
  const positions = new Float32Array([
    -halfW, -halfH,  halfW, -halfH,  -halfW, halfH,
    -halfW,  halfH,  halfW, -halfH,   halfW, halfH,
  ]);
  const texCoords = new Float32Array([
    0, 1,  1, 1,  0, 0,
    0, 0,  1, 1,  1, 0,
  ]);

  glBuffers = { position: gl.createBuffer(), texCoord: gl.createBuffer() };
  gl.bindBuffer(gl.ARRAY_BUFFER, glBuffers.position);
  gl.bufferData(gl.ARRAY_BUFFER, positions, gl.STATIC_DRAW);
  gl.bindBuffer(gl.ARRAY_BUFFER, glBuffers.texCoord);
  gl.bufferData(gl.ARRAY_BUFFER, texCoords, gl.STATIC_DRAW);

  videoTexture = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, videoTexture);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
}

// --- tiny mat4 helpers (column-major, matching WebGL/WebXR convention) ---

function mat4Identity() {
  return new Float32Array([1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]);
}

function mat4Translate(m, x, y, z) {
  const out = m.slice();
  out[12] = m[0]*x + m[4]*y + m[8]*z + m[12];
  out[13] = m[1]*x + m[5]*y + m[9]*z + m[13];
  out[14] = m[2]*x + m[6]*y + m[10]*z + m[14];
  out[15] = m[3]*x + m[7]*y + m[11]*z + m[15];
  return out;
}

function mat4Multiply(a, b) {
  const out = new Float32Array(16);
  for (let col = 0; col < 4; col++) {
    for (let row = 0; row < 4; row++) {
      let sum = 0;
      for (let k = 0; k < 4; k++) sum += a[k * 4 + row] * b[col * 4 + k];
      out[col * 4 + row] = sum;
    }
  }
  return out;
}

function drawPanel(projectionMatrix, viewMatrix) {
  // Panel sits 2m in front of the world origin at eye height; since we use
  // a 'local-floor' space, nudge it up to roughly standing eye height.
  const model = mat4Translate(mat4Identity(), 0, 1.4, -2.0);
  const mvp = mat4Multiply(mat4Multiply(projectionMatrix, viewMatrix), model);

  gl.useProgram(glProgram);
  gl.uniformMatrix4fv(glLocations.mvp, false, mvp);

  gl.bindBuffer(gl.ARRAY_BUFFER, glBuffers.position);
  gl.enableVertexAttribArray(glLocations.position);
  gl.vertexAttribPointer(glLocations.position, 2, gl.FLOAT, false, 0, 0);

  gl.bindBuffer(gl.ARRAY_BUFFER, glBuffers.texCoord);
  gl.enableVertexAttribArray(glLocations.texCoord);
  gl.vertexAttribPointer(glLocations.texCoord, 2, gl.FLOAT, false, 0, 0);

  gl.activeTexture(gl.TEXTURE0);
  gl.bindTexture(gl.TEXTURE_2D, videoTexture);
  if (previewEl.readyState >= previewEl.HAVE_CURRENT_DATA) {
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, previewEl);
  }
  gl.uniform1i(glLocations.videoTexture, 0);

  gl.drawArrays(gl.TRIANGLES, 0, 6);
}

function onXRFrame(time, frame) {
  const session = frame.session;
  session.requestAnimationFrame(onXRFrame);

  const pose = frame.getViewerPose(xrRefSpace);
  if (!pose) return;

  const glLayer = session.renderState.baseLayer;
  gl.bindFramebuffer(gl.FRAMEBUFFER, glLayer.framebuffer);
  gl.clearColor(0.02, 0.02, 0.03, 1.0);
  gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
  gl.enable(gl.DEPTH_TEST);

  for (const view of pose.views) {
    const viewport = glLayer.getViewport(view);
    gl.viewport(viewport.x, viewport.y, viewport.width, viewport.height);
    drawPanel(view.projectionMatrix, view.transform.inverse.matrix);
  }
}

async function onEnterVR() {
  if (!navigator.xr) {
    setStatus('WebXR is not available in this browser.');
    return;
  }
  if (!gl) initGL();

  xrSession = await navigator.xr.requestSession('immersive-vr', {
    optionalFeatures: ['local-floor'],
  });
  await gl.makeXRCompatible();
  xrSession.updateRenderState({ baseLayer: new XRWebGLLayer(xrSession, gl) });

  try {
    xrRefSpace = await xrSession.requestReferenceSpace('local-floor');
  } catch {
    xrRefSpace = await xrSession.requestReferenceSpace('local');
  }

  xrSession.addEventListener('end', () => {
    xrSession = null;
  });

  xrSession.requestAnimationFrame(onXRFrame);
}

enterVRButton.addEventListener('click', onEnterVR);

if (navigator.xr) {
  navigator.xr.isSessionSupported('immersive-vr').then((supported) => {
    if (!supported) setStatus('This browser does not support immersive-vr.');
  });
} else {
  setStatus('WebXR is not available in this browser.');
}

connectSignaling();
