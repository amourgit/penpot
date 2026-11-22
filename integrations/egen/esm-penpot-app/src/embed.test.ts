import { beforeEach, describe, expect, it, vi } from 'vitest';

// `esm-nextjs-utils` est testé dans le Framework (18 tests) : ici on vérifie ce que NOTRE enveloppe lui demande
// et ce qu'elle fait de l'iframe obtenue. La doublure crée une vraie iframe dans la cible, comme l'original.
const embedCalls: any[] = [];
const embedMount = vi.fn();
const embedUnmount = vi.fn();

vi.mock('@egen-civitas/esm-nextjs-utils', () => ({
  getEmbedLifecycle: (opts: any) => {
    embedCalls.push(opts);
    return {
      mount: async (props: any) => {
        embedMount(props);
        const iframe = document.createElement('iframe');
        iframe.src = opts.url;
        iframe.title = opts.title;
        iframe.setAttribute('sandbox', opts.sandbox);
        props.domElement.appendChild(iframe);
      },
      unmount: async (props: any) => {
        embedUnmount(props);
        props.domElement.querySelector('iframe')?.remove();
      },
    };
  },
}));

vi.mock('@egen-civitas/esm-integration-utils', () => ({
  resolveMountTarget: (props: { domElement: HTMLElement }) => props.domElement,
}));

import { IFRAME_ALLOW, IFRAME_SANDBOX, MIN_HEIGHT, PenpotConfigError, createPenpotLifecycle, normalizeConfig } from './embed';

describe('normalizeConfig', () => {
  it('accepte une URL https et en déduit l’origine', () => {
    const cfg = normalizeConfig({ penpotUrl: 'https://design.exemple.org/' });
    expect(cfg).toEqual({ url: 'https://design.exemple.org/', origin: 'https://design.exemple.org', title: 'Penpot', heightOffset: 0 });
  });

  it('conserve un port et un chemin', () => {
    const cfg = normalizeConfig({ penpotUrl: ' https://exemple.org:8443/penpot ' });
    expect(cfg.origin).toBe('https://exemple.org:8443');
    expect(cfg.url).toBe('https://exemple.org:8443/penpot');
  });

  it.each(['http://localhost:9001', 'http://127.0.0.1:9001/'])('tolère http vers l’hôte local : %s', (url) => {
    expect(normalizeConfig({ penpotUrl: url }).origin).toMatch(/^http:\/\//);
  });

  it.each([
    [undefined, 'pas défini'],
    [{}, 'pas défini'],
    [{ penpotUrl: '   ' }, 'pas défini'],
    [{ penpotUrl: 'design.exemple.org' }, 'pas une URL valide'],
    [{ penpotUrl: 'http://design.exemple.org' }, 'https'],
    [{ penpotUrl: 'ftp://design.exemple.org' }, 'https'],
    [{ penpotUrl: 'javascript:alert(1)' }, 'https'],
    [{ penpotUrl: 'https://user:secret@design.exemple.org' }, 'identifiant'],
    [{ penpotUrl: 'https://design.exemple.org', heightOffset: -1 }, 'heightOffset'],
    [{ penpotUrl: 'https://design.exemple.org', heightOffset: 99999 }, 'heightOffset'],
    [{ penpotUrl: 'https://design.exemple.org', heightOffset: Number.NaN }, 'heightOffset'],
  ])('refuse une configuration invalide : %j', (raw, fragment) => {
    expect(() => normalizeConfig(raw as any)).toThrow(PenpotConfigError);
    expect(() => normalizeConfig(raw as any)).toThrow(new RegExp(fragment));
  });

  it('borne et nettoie le titre', () => {
    expect(normalizeConfig({ penpotUrl: 'https://a.org', title: '  Mon design  ' }).title).toBe('Mon design');
    expect(normalizeConfig({ penpotUrl: 'https://a.org', title: 'x'.repeat(500) }).title).toHaveLength(200);
    expect(normalizeConfig({ penpotUrl: 'https://a.org', title: '   ' }).title).toBe('Penpot');
  });
});

describe('createPenpotLifecycle', () => {
  let domElement: HTMLElement;
  const props = () => ({ name: '@civitas/esm-penpot-app', domElement });
  const lifecycle = (config: any) =>
    createPenpotLifecycle({
      moduleName: '@civitas/esm-penpot-app',
      featureName: 'penpot',
      readConfig: () => Promise.resolve(config),
    }) as any;

  beforeEach(() => {
    embedCalls.length = 0;
    embedMount.mockClear();
    embedUnmount.mockClear();
    document.body.innerHTML = '';
    domElement = document.createElement('div');
    document.body.appendChild(domElement);
    Object.defineProperty(window, 'innerHeight', { value: 900, configurable: true, writable: true });
    vi.spyOn(console, 'error').mockImplementation(() => undefined);
  });

  it('demande à esm-nextjs-utils une origine explicite, un bac à sable et AUCUN champ de session', async () => {
    await lifecycle({ penpotUrl: 'https://design.exemple.org', title: 'Conception' }).mount(props());
    expect(embedCalls).toHaveLength(1);
    expect(embedCalls[0]).toMatchObject({
      moduleName: '@civitas/esm-penpot-app',
      url: 'https://design.exemple.org/',
      allowedOrigin: 'https://design.exemple.org',
      sandbox: IFRAME_SANDBOX,
      title: 'Conception',
      sessionFields: [],
    });
    expect(embedCalls[0].allowedOrigin).not.toBe('*');
  });

  it('le bac à sable autorise ce dont Penpot a besoin, et pas plus', () => {
    for (const token of ['allow-scripts', 'allow-same-origin', 'allow-forms', 'allow-downloads', 'allow-modals', 'allow-popups']) {
      expect(IFRAME_SANDBOX).toContain(token);
    }
    expect(IFRAME_SANDBOX).not.toContain('allow-top-navigation');
    expect(IFRAME_ALLOW).toContain('clipboard-read');
    expect(IFRAME_ALLOW).toContain('clipboard-write');
  });

  it('pose les permissions presse-papiers sur l’iframe', async () => {
    await lifecycle({ penpotUrl: 'https://design.exemple.org' }).mount(props());
    const iframe = domElement.querySelector('iframe')!;
    expect(iframe).toBeTruthy();
    expect(iframe.getAttribute('allow')).toBe(IFRAME_ALLOW);
    expect(iframe.getAttribute('sandbox')).toBe(IFRAME_SANDBOX);
  });

  it('ajuste la hauteur à l’espace visible, avec plancher et décalage', async () => {
    await lifecycle({ penpotUrl: 'https://design.exemple.org', heightOffset: 40 }).mount(props());
    const iframe = domElement.querySelector('iframe')!;
    vi.spyOn(iframe, 'getBoundingClientRect').mockReturnValue({ top: 64 } as DOMRect);
    window.dispatchEvent(new Event('resize'));
    expect(iframe.style.height).toBe(`${900 - 64 - 40}px`);

    (window as any).innerHeight = 300;
    window.dispatchEvent(new Event('resize'));
    expect(iframe.style.height).toBe(`${MIN_HEIGHT}px`);
  });

  it('cesse d’écouter la fenêtre au démontage et retire l’iframe', async () => {
    const lc = lifecycle({ penpotUrl: 'https://design.exemple.org' });
    await lc.mount(props());
    const iframe = domElement.querySelector('iframe')!;
    const removed = vi.spyOn(window, 'removeEventListener');
    await lc.unmount(props());
    expect(removed).toHaveBeenCalledWith('resize', expect.any(Function));
    expect(embedUnmount).toHaveBeenCalledTimes(1);
    expect(domElement.querySelector('iframe')).toBeNull();
    expect(iframe.isConnected).toBe(false);
  });

  it('affiche une alerte lisible (et n’embarque rien) si la configuration est invalide', async () => {
    const lc = lifecycle({ penpotUrl: 'http://design.exemple.org' });
    await lc.mount(props());
    expect(embedMount).not.toHaveBeenCalled();
    expect(domElement.querySelector('iframe')).toBeNull();
    const alert = domElement.querySelector('[role="alert"]')!;
    expect(alert.textContent).toMatch(/Penpot n'est pas disponible.*https/);
    await lc.unmount(props());
    expect(domElement.querySelector('[role="alert"]')).toBeNull();
  });

  it('relit la configuration à chaque montage', async () => {
    let url = 'https://a.exemple.org';
    const lc = createPenpotLifecycle({
      moduleName: '@civitas/esm-penpot-app',
      featureName: 'penpot',
      readConfig: () => Promise.resolve({ penpotUrl: url }),
    }) as any;
    await lc.mount(props());
    await lc.unmount(props());
    url = 'https://b.exemple.org';
    await lc.mount(props());
    expect(embedCalls.map((c) => c.allowedOrigin)).toEqual(['https://a.exemple.org', 'https://b.exemple.org']);
  });

  it('un démontage sans montage préalable est sans effet', async () => {
    await expect(lifecycle({ penpotUrl: 'https://a.org' }).unmount(props())).resolves.toBeUndefined();
  });
});
