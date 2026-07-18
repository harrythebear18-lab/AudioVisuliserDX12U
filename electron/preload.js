const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('electronAPI', {
  getAudioStatus: () => ipcRenderer.invoke('get-audio-status'),
  onAudioFrame: (callback) => ipcRenderer.on('audio-frame', (event, frame) => callback(frame)),
});
