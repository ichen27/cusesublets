/** Architectural C: an open enclosure with a clear entrance. */
export default function BrandMark({ size = 40 }: { size?: number }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 48 48"
      fill="none"
      aria-hidden="true"
      focusable="false"
    >
      <path
        d="M38 6H17L6 17V31L17 42H38V32H22L16 26V22L22 16H38V6Z"
        fill="currentColor"
      />
    </svg>
  );
}
