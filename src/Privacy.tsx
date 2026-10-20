import privacy from "../shared/privacy.json";
export default function Privacy() {
  return (
    <main className="container" style={{ maxWidth: 760, padding: "32px 20px" }}>
      <a href="/">← CuseSublets</a>
      <h1>{privacy.title}</h1>
      <p>{privacy.status}</p>
      <small>Updated {privacy.updated}</small>
      {privacy.sections.map((section) => (
        <section key={section.title} style={{ marginTop: 28 }}>
          <h2>{section.title}</h2>
          <p>{section.text}</p>
        </section>
      ))}
      <a href={privacy.supportURL}>Project support and technical feedback</a>
    </main>
  );
}
