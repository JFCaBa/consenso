## Formato de salida (obligatorio)

Responde EXCLUSIVAMENTE con un array JSON, sin texto antes ni después. Cada
elemento es un hallazgo con estas claves exactas:

- `severidad`: uno de `bloqueante` | `importante` | `menor` | `nit`
- `ubicacion`: `ruta:linea` o descripción del punto
- `problema`: qué está mal o qué riesgo hay
- `propuesta`: el cambio concreto sugerido
- `fuera_de_alcance`: `true` si no es sobre el cambio ni sobre algo que el
  cambio rompa o empeore; `false` si lo es
- `hipotetica`: `true` si depende de una entrada o un escenario que la fuente
  real no produce o el contrato no admite; `false` si no

Los dos booleanos van en TODOS los hallazgos, con `false` cuando no apliquen.

Si no encuentras nada, responde `[]`.
