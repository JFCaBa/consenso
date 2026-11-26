## Formato de salida (obligatorio)

Responde EXCLUSIVAMENTE con un objeto JSON, sin texto antes ni después, con dos
claves: `hallazgos` y `seguimiento`.

`hallazgos` es un array con los hallazgos NUEVOS (no repitas las objeciones
pendientes: esas van en `seguimiento`). Cada elemento lleva estas claves
exactas:

- `severidad`: uno de `bloqueante` | `importante` | `menor` | `nit`
- `ubicacion`: `ruta:linea` o descripción del punto
- `problema`: qué está mal o qué riesgo hay
- `propuesta`: el cambio concreto sugerido
- `fuera_de_alcance`: `true` si no es sobre el cambio ni sobre algo que el
  cambio rompa o empeore; `false` si lo es
- `hipotetica`: `true` si depende de una entrada o un escenario que la fuente
  real no produce o el contrato no admite; `false` si no

Los dos booleanos van en TODOS los hallazgos, con `false` cuando no apliquen.

`seguimiento` es un array con un elemento por objeción pendiente:

- `objecion`: su id (p.ej. `O1`), tal como viene en las objeciones pendientes
- `estado`: `resuelta` (la versión nueva la resuelve) | `sigue_abierta`
- `argumento`: por qué, con referencia al cambio

Sin hallazgos nuevos, `hallazgos` es `[]`; sin objeciones pendientes,
`seguimiento` es `[]`.
