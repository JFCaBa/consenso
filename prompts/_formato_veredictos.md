## Formato de salida (obligatorio)

Responde EXCLUSIVAMENTE con un array JSON, sin texto antes ni después. Un
elemento por punto en disputa, con estas claves exactas:

- `punto`: el `id` del punto (p.ej. `P1`), tal como viene en los puntos
- `veredicto`: uno de `mantengo` (sigues en tu postura) | `rebato` (la crítica
  contraria no se sostiene) | `cedo` (aceptas la otra postura)
- `argumento`: el argumento técnico breve que lo justifica

Un solo veredicto por punto, y uno para CADA punto.
