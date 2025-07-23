Here is a precise conceptual overview of the gamified system we've designed, summarizing the core mechanics and key considerations.

### **Core System Overview**

The system is composed of two distinct but interconnected progression loops, each serving a different psychological purpose:

1.  **Area XP System (The Main Quest):** This is your long-term progression system focused on **mastery and identity**. Each of your PARA Areas (e.g., "Expert Writer," "Healthy Athlete") is treated as a skill that you level up over years. Its purpose is to reward strategic, patient effort towards your most significant goals.

2.  **Project XP System (The Seasonal Battle Pass):** This is your short-term momentum engine focused on **execution and accomplishment**. It operates in user-defined "Seasons" (e.g., quarterly) and rewards the day-to-day work of completing tasks within your PARA Projects. Its purpose is to make work engaging and provide a steady stream of tangible rewards.

---

### **XP Functions & Curves**

The "feel" of the progression is controlled by different mathematical curves for each system.

- **Area XP Curve (Exponential):** To level up an Area, you use an **exponential curve** (e.g., $XP = 1000 \times \text{Level}^{2.5}$). This means each new level requires significantly more XP than the last. This models the real-world difficulty of true mastery, ensuring that high levels remain meaningful and hard-won achievements.

- **Project XP Curve (Polynomial & Hybrid):** This system has two curves:
  1.  **Seasonal Leveling:** To advance through the seasonal "Battle Pass" tiers, you use a **low-power polynomial curve** (e.g., $XP = 100 \times \text{Level}^{1.2}$). This provides a stable, predictable progression with a slight acceleration to keep it engaging over a short season.
  2.  **Task Rewards:** To earn the XP for the season, each project follows a **3-stage hybrid reward structure**:
      - **Initiation:** The first few tasks give a large, front-loaded amount of XP (a logarithmic reward) to overcome inertia.
      - **Execution:** The main body of tasks gives a standard, flat amount of XP (a linear reward) to maintain momentum.
      - **Completion:** The final task awards a massive XP bonus, creating a powerful incentive to finish projects.

### **How XP is Awarded & Configured**

- **User Configuration:** You, the user, can configure the core variables of the XP formulas (the base numbers and exponents) to tune the system's difficulty to your personal preference. You also manually define the start and end of each "Season" and can set your own rewards for the Battle Pass tiers.

- **Area XP Rewards:** Area XP is awarded when you complete a strategic **Objective**. The base XP value is modified by two key factors:

  - **Time-Horizon Multiplier:** Objectives with a longer planned duration (e.g., a 1-year goal) grant significantly more XP than short-term ones.
  - **Relevance Decay:** The potential XP from old, uncompleted objectives slowly decreases over time, encouraging you to focus on current priorities.

- **Project XP Rewards:** Project XP is awarded automatically as you complete **individual tasks** within a project, following the 3-stage reward model described above.

### **Key System Mechanics**

- **Area XP Bubbling (Inheritance):** This is a core feature of the Area system. When an Area gains XP, a large percentage of that XP (e.g., 75%) "bubbles up" and is also awarded to its designated `parentArea`. This process is recursive, ensuring that progress in a specific sub-skill contributes to the mastery of the broader domain.

- **System Integration (The 10% Rule):** The two systems are linked. When you complete a project, **10%** of the _total_ Project XP you earned from it is transferred as a bonus to its linked Area. This reinforces the idea that tactical execution (Projects) serves long-term strategy (Areas), without devaluing the primary method of Area growth (completing OKRs).

- **Core Consideration (Goodhart's Law):** A critical aspect to remember is the risk of "gaming your own system"—optimizing for points instead of genuine progress. The design mitigates this by encouraging regular qualitative reviews and focusing on the _process_ of doing good work, using the XP system as a guide rather than an absolute measure of success.
