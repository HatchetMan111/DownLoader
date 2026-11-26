const Svg = ({ size = 18, children, ...props }) => (
  <svg
    viewBox="0 0 24 24"
    width={size}
    height={size}
    fill="none"
    stroke="currentColor"
    strokeWidth="1.7"
    strokeLinecap="round"
    strokeLinejoin="round"
    aria-hidden="true"
    focusable="false"
    {...props}
  >
    {children}
  </svg>
);

export const Shield = (p) => (
  <Svg {...p}>
    <path d="M12 3l7 2.5v6.1c0 4.3-2.9 7.3-7 8.9-4.1-1.6-7-4.6-7-8.9V5.5L12 3z" />
    <path d="M9.2 12.1l2 2 3.6-3.9" />
  </Svg>
);

export const ShieldOff = (p) => (
  <Svg {...p}>
    <path d="M12 3l7 2.5v6.1c0 4.3-2.9 7.3-7 8.9-4.1-1.6-7-4.6-7-8.9V5.5L12 3z" />
    <path d="M9.5 9.5l5 5m0-5l-5 5" />
  </Svg>
);

export const Download = (p) => (
  <Svg {...p}>
    <path d="M12 4v10" />
    <path d="M8 10.5l4 4 4-4" />
    <path d="M5 19h14" />
  </Svg>
);

export const Folder = (p) => (
  <Svg {...p}>
    <path d="M3.5 7.5A1.5 1.5 0 015 6h3.6c.5 0 .9.2 1.2.6l.9 1.1c.3.4.7.6 1.2.6H19a1.5 1.5 0 011.5 1.5v7A1.5 1.5 0 0119 18.5H5A1.5 1.5 0 013.5 17v-9.5z" />
  </Svg>
);

export const File = (p) => (
  <Svg {...p}>
    <path d="M13.5 3.5H7A1.5 1.5 0 005.5 5v14A1.5 1.5 0 007 20.5h10a1.5 1.5 0 001.5-1.5V8.5l-5-5z" />
    <path d="M13.5 3.5v5h5" />
  </Svg>
);

export const Trash = (p) => (
  <Svg {...p}>
    <path d="M4.5 7h15" />
    <path d="M9.5 7V5.5A1.5 1.5 0 0111 4h2a1.5 1.5 0 011.5 1.5V7" />
    <path d="M6.5 7l.8 11.2A1.5 1.5 0 008.8 19.5h6.4a1.5 1.5 0 001.5-1.3L17.5 7" />
    <path d="M10.5 11v5m3-5v5" />
  </Svg>
);

export const Upload = (p) => (
  <Svg {...p}>
    <path d="M12 16V6" />
    <path d="M8 9.5l4-4 4 4" />
    <path d="M5 19h14" />
  </Svg>
);

export const Plus = (p) => (
  <Svg {...p}>
    <path d="M12 5v14M5 12h14" />
  </Svg>
);

export const Refresh = (p) => (
  <Svg {...p}>
    <path d="M19.5 12a7.5 7.5 0 01-12.9 5.2L4.5 15" />
    <path d="M4.5 12a7.5 7.5 0 0112.9-5.2L19.5 9" />
    <path d="M19.5 4.5V9H15" />
    <path d="M4.5 19.5V15H9" />
  </Svg>
);

export const Logout = (p) => (
  <Svg {...p}>
    <path d="M14 4.5H6.5A1.5 1.5 0 005 6v12a1.5 1.5 0 001.5 1.5H14" />
    <path d="M16.5 8.5L20 12l-3.5 3.5" />
    <path d="M20 12H10" />
  </Svg>
);

export const Monitor = (p) => (
  <Svg {...p}>
    <rect x="3.5" y="4.5" width="17" height="11.5" rx="1.5" />
    <path d="M9 20h6m-3-4v4" />
  </Svg>
);

export const Network = (p) => (
  <Svg {...p}>
    <circle cx="12" cy="12" r="8.5" />
    <path d="M3.5 12h17" />
    <path d="M12 3.5c2.2 2.3 3.4 5.3 3.4 8.5S14.2 18.2 12 20.5C9.8 18.2 8.6 15.2 8.6 12S9.8 5.8 12 3.5z" />
  </Svg>
);

export const Server = (p) => (
  <Svg {...p}>
    <rect x="3.5" y="4.5" width="17" height="6" rx="1.5" />
    <rect x="3.5" y="13.5" width="17" height="6" rx="1.5" />
    <path d="M7 7.5h.01M7 16.5h.01" />
  </Svg>
);

export const HardDrive = (p) => (
  <Svg {...p}>
    <path d="M4.5 13.5l1.9-6A1.5 1.5 0 017.8 6.5h8.4a1.5 1.5 0 011.4 1l1.9 6" />
    <rect x="3.5" y="13.5" width="17" height="5" rx="1.5" />
    <path d="M7 16h.01M10 16h.01" />
  </Svg>
);

export const X = (p) => (
  <Svg {...p}>
    <path d="M6 6l12 12M18 6L6 18" />
  </Svg>
);

export const ChevronRight = (p) => (
  <Svg {...p}>
    <path d="M9.5 6l6 6-6 6" />
  </Svg>
);

export const Check = (p) => (
  <Svg {...p}>
    <path d="M5 12.5l4.5 4.5L19 7.5" />
  </Svg>
);

export const Alert = (p) => (
  <Svg {...p}>
    <path d="M12 4.5L21 19.5H3L12 4.5z" />
    <path d="M12 10v4m0 2.5h.01" />
  </Svg>
);

export const Lock = (p) => (
  <Svg {...p}>
    <rect x="5" y="10.5" width="14" height="9.5" rx="1.8" />
    <path d="M8.5 10.5V8a3.5 3.5 0 017 0v2.5" />
  </Svg>
);

export const Key = (p) => (
  <Svg {...p}>
    <circle cx="8" cy="8" r="3.5" />
    <path d="M10.5 10.5L19 19m-2.5-2.5l2-2m-5 0l2-2" />
  </Svg>
);

export const Pencil = (p) => (
  <Svg {...p}>
    <path d="M4.5 19.5l4.2-1 9.6-9.6a2 2 0 000-2.8l-.4-.4a2 2 0 00-2.8 0L5.5 15.3l-1 4.2z" />
    <path d="M14.5 6.5l3 3" />
  </Svg>
);
