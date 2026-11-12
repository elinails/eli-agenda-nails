-- ============================================================================
-- ELIMA HUB · I92 · NUEVAS CATEGORÍAS DE MARKETPLACE
--
-- Amplía el CHECK de public.salones.rubro para aceptar los rubros nuevos sin
-- tocar los existentes ni los datos cargados.
--
-- Rubros previos (se conservan):
--   nails, peluqueria, maquillaje, barberia
--
-- Rubros nuevos:
--   lashes     → Cejas y Pestañas
--   skincare   → Estética Facial
--   depilacion → Depilación
--   spa        → Spa y Masajes
--   corporal   → Estética Corporal
--   tatuajes   → Tatuajes
--
-- Requisitos: I62 (columna rubro + constraint).
-- Idempotente.
-- ============================================================================

begin;

alter table public.salones
    drop constraint if exists salones_rubro_check;

alter table public.salones
    add constraint salones_rubro_check
    check (
        rubro is null
        or rubro in (
            'nails',
            'peluqueria',
            'maquillaje',
            'barberia',
            'lashes',
            'skincare',
            'depilacion',
            'spa',
            'corporal',
            'tatuajes'
        )
    );

notify pgrst, 'reload schema';

commit;
