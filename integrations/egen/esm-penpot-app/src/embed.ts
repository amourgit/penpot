import { getEmbedLifecycle } from '@egen-civitas/esm-nextjs-utils';
import { resolveMountTarget } from '@egen-civitas/esm-integration-utils';
import type { LifeCycles } from 'single-spa';
import type { ConfigSchema } from './config-schema';

/**
 * Droits du bac à sable de l'iframe. Plus larges que le défaut de `esm-nextjs-utils` parce que Penpot en a
 * besoin : exports (téléchargements), boîtes de dialogue, liens externes (hors bac à sable). Penpot reste sur
 * SA propre origine (domaine distinct du Core) : `allow-same-origin` ne lui donne que son propre stockage.
 */
export const IFRAME_SANDBOX =
  'allow-scripts allow-same-origin allow-forms allow-popups allow-popups-to-escape-sandbox allow-downloads allow-modals';

/** Permissions de l'iframe : copier-coller de formes et plein écran (non couverts par `sandbox`). */
export const IFRAME_ALLOW = 'clipboard-read; clipboard-write; fullscreen';

/** Hauteur plancher de l'iframe (px) : Penpot n'est pas utilisable en dessous. */
export const MIN_HEIGHT = 480;

export interface NormalizedConfig {
  url: string;
  origin: string;
  title: string;
  heightOffset: number;
}

export class PenpotConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'PenpotConfigError';
  }
}

const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '[::1]']);

/**
 * Valide et normalise la configuration. Refuse tout ce qui rendrait l'embarquement dangereux ou inopérant :
 * URL absente ou illisible, schéma autre que https (http seulement vers l'hôte local, pour le développement),
 * identifiants dans l'URL, titre ou décalage invalides.
 */
export function normalizeConfig(raw: Partial<ConfigSchema> | undefined | null): NormalizedConfig {
  const penpotUrl = typeof raw?.penpotUrl === 'string' ? raw.penpotUrl.trim() : '';
  if (!penpotUrl) {
    throw new PenpotConfigError("« penpotUrl » n'est pas défini : renseigner l'URL de l'instance Penpot.");
  }

  let parsed: URL;
  try {
    parsed = new URL(penpotUrl);
  } catch {
    throw new PenpotConfigError(`« penpotUrl » n'est pas une URL valide : ${penpotUrl}`);
  }

  const isHttps = parsed.protocol === 'https:';
  const isLocalHttp = parsed.protocol === 'http:' && LOCAL_HOSTS.has(parsed.hostname);
  if (!isHttps && !isLocalHttp) {
    throw new PenpotConfigError('« penpotUrl » doit être en https (http est toléré uniquement pour localhost).');
  }
  if (parsed.username || parsed.password) {
    throw new PenpotConfigError('« penpotUrl » ne doit contenir ni identifiant ni mot de passe.');
  }

  const title = typeof raw?.title === 'string' && raw.title.trim() ? raw.title.trim().slice(0, 200) : 'Penpot';

  const offset = raw?.heightOffset ?? 0;
  if (typeof offset !== 'number' || !Number.isFinite(offset) || offset < 0 || offset > 2000) {
    throw new PenpotConfigError('« heightOffset » doit être un nombre entre 0 et 2000.');
  }

  return { url: parsed.href, origin: parsed.origin, title, heightOffset: offset };
}

export interface PenpotLifecycleOptions {
  moduleName: string;
  featureName: string;
  /** Lecture de la configuration runtime (au montage, pour prendre en compte les changements). */
  readConfig: () => Promise<Partial<ConfigSchema> | undefined | null>;
}

/** Affiche un message d'erreur accessible dans la zone de montage (plutôt qu'un écran vide). */
function showError(target: HTMLElement, message: string): HTMLElement {
  const el = document.createElement('div');
  el.setAttribute('role', 'alert');
  el.style.cssText = 'padding:1rem;margin:1rem;border:1px solid currentColor;border-radius:4px';
  el.textContent = `Penpot n'est pas disponible : ${message}`;
  target.appendChild(el);
  return el;
}

/**
 * Lifecycle Single-SPA de l'app : lit la configuration, délègue l'embarquement à `getEmbedLifecycle`
 * (esm-nextjs-utils : origine explicite, bac à sable, messages vérifiés), puis ajuste l'iframe à Penpot :
 * permissions presse-papiers et hauteur = espace visible (Penpot occupe toute la fenêtre et n'annonce pas sa hauteur).
 * Aucune donnée de session n'est transmise (`sessionFields: []`) : Penpot a sa propre authentification.
 */
export function createPenpotLifecycle(options: PenpotLifecycleOptions): LifeCycles {
  const active = new Map<string, () => Promise<void>>();

  return {
    bootstrap: () => Promise.resolve(),

    mount: async (props: any) => {
      const target = resolveMountTarget(props);
      const key = String(props.name);

      let cfg: NormalizedConfig;
      try {
        cfg = normalizeConfig(await options.readConfig());
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        console.error(`[egen] ${options.moduleName} : ${message}`);
        const el = showError(target, message);
        active.set(key, () => {
          el.remove();
          return Promise.resolve();
        });
        return;
      }

      const embed = getEmbedLifecycle({
        moduleName: options.moduleName,
        featureName: options.featureName,
        url: cfg.url,
        allowedOrigin: cfg.origin,
        sandbox: IFRAME_SANDBOX,
        title: cfg.title,
        minHeight: MIN_HEIGHT,
        sessionFields: [],
      });
      await (embed.mount as (p: any) => Promise<void>)(props);

      const iframe = Array.from(target.children)
        .filter((child): child is HTMLIFrameElement => child.tagName === 'IFRAME')
        .pop();

      let teardown: () => void = () => undefined;
      if (iframe) {
        iframe.setAttribute('allow', IFRAME_ALLOW);
        const fit = () => {
          const top = Math.min(Math.max(iframe.getBoundingClientRect().top, 0), window.innerHeight);
          const height = Math.floor(window.innerHeight - top - cfg.heightOffset);
          iframe.style.height = `${Math.max(MIN_HEIGHT, height)}px`;
        };
        fit();
        const frame = window.requestAnimationFrame(fit);
        window.addEventListener('resize', fit);
        teardown = () => {
          window.cancelAnimationFrame(frame);
          window.removeEventListener('resize', fit);
        };
      }

      active.set(key, async () => {
        teardown();
        await (embed.unmount as (p: any) => Promise<void>)(props);
      });
    },

    unmount: async (props: any) => {
      const key = String(props.name);
      const stop = active.get(key);
      if (stop) {
        active.delete(key);
        await stop();
      }
    },
  } as LifeCycles;
}
