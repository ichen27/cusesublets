import { useRef, useState } from "react";
import { UploadCloud, FileText, CheckCircle2, LockKeyhole } from "lucide-react";
export default function UploadCard({
  title,
  description,
  accept = "application/pdf,image/jpeg,image/png",
  maxMB = 5,
  button = "Submit for review",
  onUpload,
  privateFile = true,
}: {
  title: string;
  description: string;
  accept?: string;
  maxMB?: number;
  button?: string;
  onUpload: (file: File) => Promise<unknown>;
  privateFile?: boolean;
}) {
  const input = useRef<HTMLInputElement>(null),
    [file, setFile] = useState<File | null>(null),
    [busy, setBusy] = useState(false),
    [error, setError] = useState(""),
    [success, setSuccess] = useState(false),
    [drag, setDrag] = useState(false);
  function choose(f?: File) {
    setSuccess(false);
    setError("");
    if (!f) return;
    if (f.size > maxMB * 1024 * 1024) {
      setError(`Choose a file under ${maxMB} MB.`);
      return;
    }
    setFile(f);
  }
  return (
    <div className="upload-card">
      <div className="upload-title">
        <span className="upload-icon">
          {privateFile ? <LockKeyhole size={19} /> : <UploadCloud size={20} />}
        </span>
        <div>
          <h4>{title}</h4>
          <p>{description}</p>
        </div>
      </div>
      <div
        className={"upload-drop " + (drag ? "dragging" : "")}
        onDragOver={(e) => {
          e.preventDefault();
          if (!busy) setDrag(true);
        }}
        onDragLeave={() => setDrag(false)}
        onDrop={(e) => {
          e.preventDefault();
          setDrag(false);
          if (!busy) choose(e.dataTransfer.files[0]);
        }}
      >
        <input
          ref={input}
          type="file"
          accept={accept}
          aria-label={title}
          disabled={busy}
          onChange={(e) => choose(e.target.files?.[0])}
        />
        <button
          type="button"
          className="upload-pick"
          disabled={busy}
          onClick={() => input.current?.click()}
        >
          {file ? <FileText size={22} /> : <UploadCloud size={24} />}
          <span>
            <b>{file ? file.name : "Select a file or drop it here"}</b>
            <small>
              {file
                ? `${Math.ceil(file.size / 1024)} KB · Click to change`
                : `${accept.includes("pdf") ? "PDF, JPG or PNG" : "JPG or PNG"} · Up to ${maxMB} MB`}
            </small>
          </span>
        </button>
      </div>
      {error && (
        <p className="upload-error" role="alert">
          {error}
        </p>
      )}
      {success && (
        <p className="upload-success" role="status">
          <CheckCircle2 size={15} /> Uploaded successfully
        </p>
      )}
      <div className="upload-bottom">
        <small>
          {privateFile
            ? "Private · Only you and authorized reviewers"
            : "Public · Shown on your profile"}
        </small>
        <button
          type="button"
          className="primary small"
          disabled={!file || busy}
          onClick={async () => {
            if (!file) return;
            setBusy(true);
            setError("");
            try {
              await onUpload(file);
              setFile(null);
              if (input.current) input.current.value = "";
              setSuccess(true);
            } catch (e) {
              setError((e as Error).message);
            } finally {
              setBusy(false);
            }
          }}
        >
          {busy ? "Uploading…" : button}
        </button>
      </div>
    </div>
  );
}
