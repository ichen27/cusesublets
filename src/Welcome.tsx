import { Home, KeyRound, ArrowRight, MapPin } from "lucide-react";
export default function Welcome({
  onChoose,
  onSkip,
}: {
  onChoose: (role: "find" | "offer") => void;
  onSkip: () => void;
}) {
  return (
    <main className="welcome-page">
      <section className="welcome-story">
        <span className="eyebrow">STUDENTS. SPACES. SYRACUSE.</span>
        <h1>
          Your next chapter.
          <br />
          Your kind of place.
        </h1>
        <p>Find a home, share your space, and meet the people around you.</p>
        <div className="welcome-photo">
          <img
            src="https://images.unsplash.com/photo-1484154218962-a197022b5858?auto=format&fit=crop&w=1100&q=85"
            alt="A bright furnished living room"
          />
          <span>
            <MapPin size={17} /> A little closer to feeling at home.
          </span>
        </div>
      </section>
      <section className="welcome-options">
        <span className="eyebrow">WELCOME TO CUSESUBLETS</span>
        <h2>
          What brings
          <br />
          you here?
        </h2>
        <p>Start with your plans. You can do both, and change them any time.</p>
        <button className="role-choice" onClick={() => onChoose("find")}>
          <Home size={28} />
          <span>
            <strong>Find a place</strong>
            <small>Tell us what feels like home.</small>
          </span>
          <ArrowRight size={20} />
        </button>
        <button className="role-choice" onClick={() => onChoose("offer")}>
          <KeyRound size={28} />
          <span>
            <strong>Offer my place</strong>
            <small>Meet someone who fits your space.</small>
          </span>
          <ArrowRight size={20} />
        </button>
        <button className="text-button explore-skip" onClick={onSkip}>
          Just exploring? Skip for now <ArrowRight size={16} />
        </button>
        <small className="welcome-note">
          Your search stays private until you turn it on. Listings go live only
          when you publish.
        </small>
      </section>
    </main>
  );
}
