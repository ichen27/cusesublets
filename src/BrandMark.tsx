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
        d="M42 16a19 19 0 1 0 0 16L31 28a7 7 0 1 1 0-8Z"
        fill="currentColor"
      />
    </svg>
  );
}
