import { defineConfigSchema, getConfig, getSyncLifecycle } from '@egen-civitas/esm-framework';
import { toLifecycleExport } from '@egen-civitas/esm-integration-utils';
import { configSchema } from './config-schema';
import { createPenpotLifecycle } from './embed';
import RailPanel from './rail-panel.component';

// =============================================================================
//  ESM PENPOT APP — application externe : affiche une instance Penpot (conception, maquettes,
//  prototypes) dans la zone principale du Core, via une iframe. Voir README.md.
// =============================================================================

export const importTranslation = require.context('../translations', false, /.json$/, 'lazy');

const moduleName = '@civitas/esm-penpot-app';

export function startupApp() {
  defineConfigSchema(moduleName, configSchema);
}

// Page de la zone principale (route `penpot`) : l'iframe Penpot.
export const root = toLifecycleExport(
  createPenpotLifecycle({
    moduleName,
    featureName: 'penpot',
    readConfig: () => getConfig(moduleName),
  }),
);

// Extension de navigation (slot `topbar-nav-slot`) : ne rend rien, seule sa `meta` (routes.json) est lue.
export const navEntry = getSyncLifecycle(() => null, { featureName: 'penpot-nav-entry', moduleName });

// Option globale du rail gauche (slot `shell-rail-left-slot`) : ses sous-options se chargent dans la zone gauche.
export const railPanel = getSyncLifecycle(RailPanel, { featureName: 'penpot-rail', moduleName });
