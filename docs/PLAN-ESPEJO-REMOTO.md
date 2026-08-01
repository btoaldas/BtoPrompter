# Plan — Ver el guion en el teléfono con karaoke sincronizado

**Fecha:** 1 de agosto de 2026 · **Base:** v0.0.4 · **Prioridad:** 2 de 2 (tras la grabación)

> **Estado de la evidencia.** Investigación con 9 agentes, de los que **6 completaron** antes de agotarse el límite de la sesión; la síntesis final la escribo yo a partir de esos 6. Lo verificado se hizo contra el **código fuente de WebKit** y las **cabeceras del SDK MacOSX26.5** instaladas en este Mac, más binarios de prueba compilados aquí. **No hay ningún iPhone ni simulador de iOS en esta máquina** (`xcrun simctl list devices available` devuelve vacío), así que **nada del lado móvil se probó en un dispositivo real**. Lo marco explícitamente donde toca.

---

## 0. Hallazgo urgente de seguridad — ya corregido

Antes de nada, algo que la investigación encontró en la configuración **real** de este Mac y que no admitía espera:

```
remoteEnabled = 1
remoteComputerControl = 1
token = 8 caracteres hexadecimales
```

Con el control del ordenador encendido, la ruta `/input` acepta `do=type` y `do=key`. Es decir: **quien tenga el token puede escribir en el Mac**. Y escribir en el Mac es abrir Spotlight, teclear `Terminal`, pulsar Enter y ejecutar lo que quiera. El guion del discurso es el activo menor aquí; **la joya es el Mac**.

Un token de 8 caracteres hexadecimales son 32 bits. En una red de hotel o de universidad eso no es una barrera seria, y además viaja **en la URL sobre HTTP plano**, donde cualquiera en la misma red puede leerlo.

**Acción tomada:** control del ordenador y servidor remoto **apagados** en este Mac (1 de agosto). Se vuelven a encender cuando estén las mitigaciones de la sección 6.

---

## 1. Resumen honesto

**Lo que se puede lograr bien:** el guion completo en el teléfono, con la misma palabra resaltada que en el Mac, desplazamiento suave, letra grande ajustable, guías en azul, espejado horizontal para teleprompters de espejo, y los controles que ya existen. El canal de datos es sencillo y barato.

**El problema serio, y no tiene una solución cómoda:** *mantener encendida la pantalla del móvil*.

**Lo que NO es viable como se esperaba:** ni `navigator.wakeLock` ni el truco del vídeo mudo en bucle funcionan sobre `http://` plano en Safari de iOS. Verificado leyendo el código fuente de WebKit, no de memoria. Esto significa que **la pantalla del iPhone se apagará a mitad del discurso** salvo que se resuelva (sección 5).

**Esfuerzo realista:** 3–5 días para el espejo funcionando sobre HTTP, más 2–3 días de endurecimiento de seguridad (obligatorio antes de mandar el texto por la red), más 3 días de los cinco modos de vista. Si además se quiere HTTPS local para desbloquear el bloqueo de pantalla, sumar 2–4 días **con riesgo de que no sirva de nada** (sección 5).

---

## 2. Transporte: decidido

**Server-Sent Events sobre el mismo servidor, el mismo puerto y el mismo token que ya existen.** Los comandos siguen yendo por `fetch` a `/cmd`; lo nuevo es un canal de bajada `/events` que el móvil abre una vez y queda escuchando.

Coste estimado: **40–60 líneas de Swift** en `RemoteControl.swift` (registro de clientes conectados, ruta `/events`, difusión cuando cambia `currentIndex`) y **~30 líneas de JavaScript** en la página.

**Un descubrimiento que ahorra trabajo:** el Network framework ya trae servidor WebSocket nativo (`NWProtocolWebSocket`), así que la idea de implementar el protocolo a mano con SHA-1 era innecesaria. Aun así **se descarta WebSocket**: para mandar un número varias veces por segundo, SSE es más simple, se reconecta solo y no necesita un segundo puerto.

**Qué se manda:**
1. Al conectar, el guion completo una sola vez (un guion de 5.000 palabras cabe de sobra en un JSON razonable).
2. Después, solo el índice de palabra y el estado, varias veces por segundo.
3. El guion se reenvía únicamente al cambiar de discurso o al reparsear.

**Cambio necesario en el servidor actual:** hoy cierra la conexión en cuanto responde (`conn.cancel()`). Hay que permitir conexiones persistentes sin bloquear el bucle que acepta clientes nuevos.

---

## 3. Arquitectura

```
Sources/Core/
├── RemoteMirrorState.swift    Qué se manda al móvil y cuándo: serializa el guion
│                              (con guías y marcas) y difunde el índice. Es el
│                              único que conoce el formato del protocolo.
└── (RemoteControl.swift)      + ruta /events, + registro de clientes, + difusión.
                               Se toca lo mínimo; el resto queda igual.

Sources/Storage/
└── (Settings.swift)           + claves: viewMode, mirrorEnabled, mirrorFontScale,
                               mirrorMirrored (espejado), remoteTokenLength.

Sources/UI/
├── ViewModePicker.swift       Selector de los cinco modos (Configuración y barra).
└── (RemotePage)               La página del móvil crece: pestaña "Guion" nueva,
                               junto a Teleprompter y Ordenador.
```

Ningún archivo existente se reescribe. `PrompterPanel`, la invisibilidad y el modo minimalista quedan intactos.

---

## 4. El karaoke en el móvil

- **Estructura:** un elemento por palabra alrededor de la posición actual, no las 5.000 de golpe. Se descartó `content-visibility` como optimización: la verificación adversarial encontró que **rompe el karaoke** (un error técnico que habría costado horas de depuración).
- **Desplazamiento:** `transform: translateY` con transición, manteniendo la palabra actual centrada. Evita el tirón cuando llegan actualizaciones seguidas.
- **Legibilidad:** tamaño de letra ajustable desde el propio móvil con pinza, contraste alto, tema oscuro, y los mismos colores que el Mac (guías en azul, palabra actual en el color elegido).
- **Espejado horizontal** con `transform: scaleX(-1)`, para teleprompters físicos con espejo. Una hora de trabajo.
- **Gestos:** tocar para pausar, deslizar para saltar, pinza para el tamaño.
- **Pantalla completa** al añadir la página a la pantalla de inicio del iPhone, sin las barras de Safari.

---

## 5. El problema de la pantalla que se apaga

Esto merece su propia sección porque es lo único que puede arruinar la función en una conferencia real.

**Lo verificado en el código fuente de WebKit:**
- `navigator.wakeLock` **no existe** cuando la página se sirve por `http://` en una IP de la red local. WebKit solo considera "seguro" `https://` y `localhost`.
- El apaño clásico del **vídeo mudo en bucle tampoco funciona** en WebKit actual.

**Las tres salidas, ordenadas por sensatez:**

| Opción | Coste | Pega |
|---|---|---|
| **A. Que el usuario ponga el móvil en «Bloqueo automático → Nunca»** | 0 | Hay que acordarse antes de cada presentación. La app lo recuerda con un aviso en la página. |
| **B. HTTPS local con certificado propio** | 2–4 días | **Riesgo alto:** no está verificado que Safari de iOS 26 conceda `wakeLock` tras aceptar un certificado autofirmado en una IP. Si no lo concede, esos días no sirven de nada. |
| **C. Un vídeo real reproduciéndose** | 0,5 día | Consume batería y es frágil. |

**Recomendación:** empezar por **A**, con un aviso claro en la página del móvil. Evaluar **B** solo después, y **solo tras comprobarlo en un iPhone real** — cosa que aquí no se pudo hacer.

---

## 6. Seguridad: obligatorio antes de mandar el texto

Hoy por la red solo viajan órdenes. En cuanto viaje el guion, el listón sube. Estas son las mitigaciones, separadas entre lo que no admite discusión y lo opcional.

**Obligatorio (1–2 días, aquí está casi todo el valor):**
- Token de **128 bits** en vez de 32, y comparación en **tiempo constante** (para no filtrarlo midiendo tiempos de respuesta).
- **Separar permisos:** ver el guion y controlar el ordenador deben ser dos autorizaciones distintas. Que alguien pueda pasar diapositivas no significa que pueda escribir en el Mac.
- Validar la cabecera `Host`, añadir `no-store`, y **escapar el guion** al insertarlo en la página (si un discurso contiene `<script>`, no puede ejecutarse).
- **Apagar el servidor al salir del prompter.** Ahora mismo se queda escuchando indefinidamente.
- Botón para **regenerar el token** y límite de clientes.
- Tiempos de espera en el parser de peticiones.

**Opcional:**
- HTTPS local (ver sección 5; el certificado se puede generar dentro de la app, sin dependencias).
- Bonjour para no teclear la dirección — con cuidado: los permisos de red local en desarrollo son difíciles de revertir.

---

## 7. Los cinco modos de vista

Esfuerzo: **~3 días**. Se sustituyen los booleanos sueltos por un único `ViewMode`, con migración de la preferencia actual.

**El riesgo está en «solo remota»**, donde el Mac no muestra nada. Si se oculta la ventana y se cambia la política de activación para que no salga del Dock, quedan dudas **no verificadas**: si los atajos globales siguen llegando en ese estado (solo se comprobó que el registro no da error, no que las pulsaciones lleguen).

**Salida de emergencia — innegociable.** Alberto no puede quedarse sin acceso a su Mac en plena conferencia porque se le acabe la batería del móvil o se caiga el Wi-Fi. El diseño incluye varias puertas de vuelta y un **vigilante de latido**: si el móvil deja de dar señales durante unos segundos, el Mac recupera la vista solo.

---

## 8. Fases

| Fase | Qué entrega | Días |
|---|---|---|
| **1. Endurecer el servidor** | Token de 128 bits, permisos separados, escapado, apagado al salir del prompter. **Antes de mandar una sola palabra del guion.** | 1–2 |
| **2. Canal en vivo** | SSE sobre el servidor existente; el móvil recibe el índice. Verificable con `curl`. | 1 |
| **3. Karaoke en el móvil** | Guion completo, palabra resaltada, desplazamiento suave, tamaño ajustable, espejado. | 2–3 |
| **4. Los cinco modos** | `ViewMode`, selector, y la salida de emergencia probada a conciencia. | 3 |
| **5. Pantalla encendida** | Aviso y, si se decide, la prueba de HTTPS **en un iPhone real**. | 0,5 – 4 |

---

## 9. Lo que NO se debe hacer

- **WebSocket a mano.** Innecesario: SSE basta y el sistema ya trae WebSocket nativo si algún día hiciera falta.
- **`content-visibility`** en la lista de palabras: rompe el karaoke.
- **Dar por hecho el HTTPS local** sin probarlo antes en un iPhone de verdad.
- **Dejar el control del ordenador encendido** cuando no se está usando.

---

## 10. Lo que queda sin verificar

Con honestidad, porque condiciona la confianza en este plan:

1. **Nada se probó en un iPhone o iPad real.** No hay dispositivo ni simulador en este Mac. Todo lo de iOS sale del código fuente de WebKit y de la documentación.
2. **Si Safari de iOS 26 concede el bloqueo de pantalla tras aceptar un certificado autofirmado.** Es la incógnita que decide si la opción B vale la pena.
3. **Si los atajos globales siguen llegando** con la ventana oculta y la app fuera del Dock.
4. Tres de los nueve agentes de investigación no llegaron a terminar por agotarse el límite de la sesión; sus áreas (verificación del transporte y de los modos de vista) quedaron con una sola pasada en vez de dos.
