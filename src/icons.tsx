import type { SVGProps } from 'react'

const Icon = ({ children, ...props }: SVGProps<SVGSVGElement>) => (
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" {...props}>{children}</svg>
)
export const PlusIcon = (props: SVGProps<SVGSVGElement>) => <Icon {...props}><path d="M12 5v14M5 12h14" /></Icon>
export const PlayIcon = (props: SVGProps<SVGSVGElement>) => <Icon {...props}><path d="m9 7 8 5-8 5V7Z" /></Icon>
export const PauseIcon = (props: SVGProps<SVGSVGElement>) => <Icon {...props}><path d="M9 7v10M15 7v10" /></Icon>
export const ExpandIcon = (props: SVGProps<SVGSVGElement>) => <Icon {...props}><path d="M8 3H3v5M16 3h5v5M21 16v5h-5M3 16v5h5" /></Icon>
export const CollapseIcon = (props: SVGProps<SVGSVGElement>) => <Icon {...props}><path d="m8 3-5 5M16 3l5 5M21 16l-5 5M3 16l5 5" /></Icon>
export const SoundIcon = (props: SVGProps<SVGSVGElement>) => <Icon {...props}><path d="M5 10v4h4l5 4V6l-5 4H5Z" /><path d="M17 9.5a3.5 3.5 0 0 1 0 5M19.5 7a7 7 0 0 1 0 10" /></Icon>
export const LiveIcon = (props: SVGProps<SVGSVGElement>) => <Icon {...props}><circle cx="12" cy="12" r="3" /><path d="M5.6 8.4a7.5 7.5 0 0 0 0 7.2M18.4 8.4a7.5 7.5 0 0 1 0 7.2M3 5.6a11 11 0 0 0 0 12.8M21 5.6a11 11 0 0 1 0 12.8" /></Icon>
export const ExportIcon = (props: SVGProps<SVGSVGElement>) => <Icon {...props}><path d="M12 3v12M8 7l4-4 4 4" /><path d="M5 13v6h14v-6" /></Icon>
export const FilmIcon = (props: SVGProps<SVGSVGElement>) => <Icon {...props}><rect x="3" y="5" width="18" height="14" rx="2" /><path d="M7 5v14M17 5v14M3 9h4M17 9h4M3 15h4M17 15h4" /></Icon>
export const CloseIcon = (props: SVGProps<SVGSVGElement>) => <Icon {...props}><path d="m7 7 10 10M17 7 7 17" /></Icon>
export const ClearIcon = (props: SVGProps<SVGSVGElement>) => <Icon {...props}><path d="M4 7h16M10 11v5M14 11v5M9 7l1-3h4l1 3M6 7l1 13h10l1-13" /></Icon>
export const FolderIcon = (props: SVGProps<SVGSVGElement>) => <Icon {...props}><path d="M3 7.5h7l2-2h9v13H3v-11Z" /></Icon>
export const InfoIcon = (props: SVGProps<SVGSVGElement>) => <Icon {...props}><circle cx="12" cy="12" r="9" /><path d="M12 11v6M12 7.5h.01" /></Icon>
export const CheckIcon = (props: SVGProps<SVGSVGElement>) => <Icon {...props}><path d="m5 12 4 4L19 6" /></Icon>
export const UpdateIcon = (props: SVGProps<SVGSVGElement>) => <Icon {...props}><path d="M20 11a8 8 0 1 0 2 5.5" /><path d="M20 4v7h-7" /><path d="M12 8v8M9 13l3 3 3-3" /></Icon>
export const FeedbackIcon = (props: SVGProps<SVGSVGElement>) => <Icon {...props}><rect x="3" y="5" width="18" height="14" rx="2" /><path d="m4 7 8 6 8-6" /></Icon>
export const PhotosIcon = (props: SVGProps<SVGSVGElement>) => <Icon {...props}><circle cx="12" cy="12" r="2" /><path d="M12 4c2-3 6 0 4 3 4-1 5 4 2 5 3 2 1 6-2 5 1 4-4 5-5 2-2 3-6 1-5-2-4 1-5-4-2-5-3-2-1-6 2-5 0-4 5-5 6-1Z" /></Icon>
