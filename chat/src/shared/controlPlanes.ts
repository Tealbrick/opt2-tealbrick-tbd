export interface ControlPlaneProfile {
  id: string;
  name: string;
  issuer: string;
  builtIn: boolean;
}

export interface ControlPlaneState {
  activeId: string;
  profiles: ControlPlaneProfile[];
}

/** The hosted Teal Brick Portal: the built-in default (C257); main's COMPANY_CONTROL_PLANE. */
export const DEFAULT_ISSUER = "https://portal.tealbrick.com";
