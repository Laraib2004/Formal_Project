// --- DICHIARAZIONI GLOBALI OBBLIGATORIE ---
ingredients = ["water", "salt", "pasta", "oil", "garlic", "tomato", "sauce"];
tools = ["pot", "pan", "colander", "bowl"];

// --- SOTTO-PROCEDIMENTI (FUNZIONI) ---
prepare_pasta {
    retrieve(pot);               // Sposta 'pot' nello scope locale
    pot += water(1, L);          // Costruttore quantità/unità + operatore +=
    pot += salt(10, g);

    cook(water, pot, 10, min);   // Chiamata built-in a 4 argomenti

    pot += pasta(100, g);
    boil(pasta, pot, 10, min);

    retrieve(colander);
    drain(pot, colander);        // Azione di scolatura

    return pasta;                // Restituisce l'ingrediente cucinato e pronto
}

prepare_sauce {
    retrieve(pan);
    pan += oil(20, g);
    pan += garlic(1, p);
    cook(garlic, pan, 2, min);

    pan += tomato(200, g);
    cook(tomato, pan, 15, min);

    return sauce;
}

// --- BLOCCO PRINCIPALE (MAIN) ---
recipe Pasta_Tomato_Sauce {
    p_cotta = prepare_pasta();
    sugo_pronto = prepare_sauce();

    retrieve(bowl);
    bowl += p_cotta;             // Uniamo la pasta cotta nella ciotola
    bowl += sugo_pronto;         // Uniamo il sugo nella ciotola

    mix(bowl);
    serve(bowl);
}