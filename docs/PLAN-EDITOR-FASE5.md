# Fase 5 — Estudio de cursos y tutoriales (dictado de Alberto, 2026-08-01)

*Dos sistemas en uno: el teleprompter que ya existe, y un ESTUDIO DE GRABACIÓN
Y EDICIÓN que funciona por su cuenta. Documentado antes de implementar.*

---

## 1. Grabación independiente del teleprompter — ✅ PRIMER PASO HECHO

Alberto: «algunas veces no necesitamos teleprompter; solo grabar la pantalla,
grabarme a mí y el sonido». El motor de grabación YA era independiente (no
mira el guion para nada), pero el botón vivía solo en la barra del prompter.

- ✅ HECHO: ítem de menú **«Grabar / Detener grabación» (⌘R)**, visible en
  cuanto la grabación está activada en Ajustes. Graba sin entrar al guion.
- ✅ HECHO: **subtítulos desde el AUDIO** (`SubtitleTranscriber`), sin guion:
  Apple devuelve el instante de cada palabra y de ahí salen las frases. Y de
  ahí encadenan las traducciones y el doblaje que ya existen.
- PENDIENTE: botón de grabar también en la ventana del editor y en el
  sidebar del editor de discursos, para no depender del menú.
- PENDIENTE: modo «Estudio» — una ventana propia con vista previa de cámara,
  selector de fuentes y botón grande de grabar, sin pasar por el prompter.

## 2. Recursos de curso: anotaciones sobre el vídeo (LO GRANDE)

Alberto: «subrayados, flechitas, rombos, cuadrados, bolitas, notas, señalar
como si fuera un marcador — como los recursos que dibujan en Canva».

**Diseño propuesto — una capa más, no un sistema aparte:**
- `ExtraLayer.Kind` gana el caso `.shape`, con `ShapeContent`:
  `{kind: .arrow|.rect|.ellipse|.diamond|.underline|.freehand|.note,
    color, thickness, points: [NRect-normalizados], text?}`.
- Se dibujan con Core Image/CGContext igual que los subtítulos (cacheadas por
  geometría), así que heredan GRATIS todo lo que ya tienen las capas:
  intervalos de aparición (aparece en el segundo 12, desaparece en el 15),
  orden por tramo, opacidad, y el lienzo vivo para moverlas con el ratón.
- Herramientas en el lienzo vivo: una barra con flecha / rectángulo / elipse /
  rombo / subrayado / lápiz libre / nota adhesiva. Se dibuja arrastrando
  sobre la previsualización y queda como capa seleccionable.
- **Animación de entrada** (opcional): la flecha «crece» y el subrayado «se
  pinta» en 300 ms — el compositor ya sabe interpolar por instante (lo hace
  con el fundido).

## 3. Zoom por tramo — YA EXISTE, falta la interfaz cómoda

Alberto: «hago un corte y hago un zoom de eso, sigo hablando, y en otro corte
regreso». Esto ES el recorte manual de la fuente por tramo que ya está en el
editor (`SourceSettings.fit = .crop` sobre la pantalla): recortar al 40 %
centrado en una zona = zoom a esa zona, solo en ese tramo.

- PENDIENTE (comodidad, no motor): botón **«Zoom aquí»** que, sobre la
  previsualización, deje dibujar el rectángulo al que hacer zoom y rellene el
  recorte del tramo. Y un preset **«Volver al 100 %»**.
- PENDIENTE: rampa de zoom (que el acercamiento sea suave en 400 ms en vez de
  un salto) — mismo mecanismo que la transición de fundido.

## 4. Voz → texto → subtítulos — ✅ HECHO

`SubtitleTranscriber`: transcribe el audio de la grabación con el motor de
Apple (local si está disponible) y arma las frases con los tiempos REALES de
cada palabra. Verificado en la interfaz: 3 frases desde un audio de prueba,
pintadas en la previsualización.

- PENDIENTE: elegir el idioma del audio (hoy fijo es-ES con respaldo).
- PENDIENTE: usar los proveedores STT de nube que la app ya tiene
  (Deepgram, ElevenLabs…) cuando el usuario los prefiera, para audio difícil.

## 4b. Aislar la voz del sonido del sistema — MEDIDO, PENDIENTE de hacer bien

Problema real (Alberto, 2026-08-01): al grabar el sonido del sistema Y hablar,
el micrófono capta también lo que sale por los altavoces y la voz queda
duplicada.

**Lo que se probó y NO sirve** (medido en esta Mac, no supuesto):
- `setVoiceProcessingEnabled(true)` (la cancelación de eco de macOS, la misma
  familia que usan Zoom y Teams) **no borra del micrófono el audio de OTRAS
  apps**. Solo lo ATENÚA: con el atenuado activo el micrófono salía limpio
  (−64 dB) pero el sonido del sistema quedaba casi mudo (−54 dB) — justo lo
  que hay que conservar. Con el atenuado al mínimo el sistema se oye bien
  (−28 dB) pero el micrófono vuelve a captarlo (−25 dB). No hay punto medio.
- Además, grabar el micrófono en un archivo aparte **descuadraba el montaje**:
  arrancaba ~2 s antes que la cámara. Se retiró; el micrófono vuelve a ir
  dentro del archivo de cámara, sincronizado por construcción.

**Lo que SÍ puede funcionar (pendiente):**
1. **Auriculares** — cero código, separación perfecta. Es la respuesta
   práctica y hay que decirla en la interfaz (ya se dice).
2. **Cancelación en POST-proceso**: tenemos la pista del sistema en DIGITAL
   (dentro de pantalla-*.mov, capturada por ScreenCaptureKit, sin pasar por
   el aire) y la del micrófono. Con la referencia perfecta se puede restar:
   alinear por correlación cruzada y aplicar un filtro adaptativo (NLMS).
   Es MEJOR que la cancelación en vivo, porque la referencia es exacta.
   Ojo: hay que compensar el retardo acústico + de salida, medido en ~0,38 s
   en esta Mac.
3. **Puerta por referencia** (más simple, menos fino): bajar el micrófono
   automáticamente cuando la pista del sistema esté sonando fuerte.

## 5. Ideas propias que encajan con esto

- **Cursor resaltado**: un halo suave siguiendo el puntero en la grabación de
  pantalla (los tutoriales lo agradecen). El sidecar tendría que registrar la
  posición del ratón al grabar — barato — y el compositor lo dibuja.
- **Pulsaciones de teclas en pantalla**: mostrar «⌘S» abajo cuando se pulsa,
  clásico de los tutoriales. Requiere permiso de Accesibilidad (ya lo hay para
  el remoto) y es una capa más.
- **Silencios fuera**: detectar tramos sin voz y proponer cortarlos (el
  transcriptor ya da los tiempos de las palabras; los huecos son silencios).

## Orden sugerido

1. ✅ Menú de grabación sin prompter + subtítulos desde el audio.
2. Anotaciones: flecha, rectángulo, elipse y subrayado (las cuatro que más se
   usan) con la barra de herramientas en el lienzo vivo.
3. «Zoom aquí» dibujando el rectángulo + rampa suave.
4. Nota adhesiva y lápiz libre.
5. Cursor resaltado y pulsaciones en pantalla.
