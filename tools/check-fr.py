# -*- coding: utf-8 -*-
"""The French locale must not spell a word two ways.

    python tools/check-fr.py


fr.lua opens with "v-phone | Français" and its first hundred strings are written properly. Further
in the accents stopped: `telephone` appeared 41 times beside `téléphone`, `numero` 32 times beside
`numéro`, `ecran` 10 times beside `écran`. 139 words were spelled both ways in the one file, over
1122 occurrences - on screen, in French, on a French server.

A word that appears accented somewhere in this file and unaccented somewhere else is not a style
choice. One of the two is wrong. That is the whole check, and it needs no dictionary: the file is
its own authority on how it spells things.

**HOMOGRAPHS are the exception, and they are listed rather than guessed at.** French has pairs
where both spellings are real and only the sentence decides - `a` and `à`, `la` and `là`, `ou`
and `où`, `passe` and `passé`. A checker that flagged those would cry wolf 600 times and be
switched off, which is how a check dies. Each entry below is a pair that genuinely exists.

Anything NOT on that list is a spelling this file contradicts itself about, and is a failure.
"""
import collections
import io
import os
import re
import sys
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

#: A Lua string in either quoting style, with the OTHER quote allowed inside it.
#:
#: The first version excluded both quote characters from the body, which was fine right up until
#: the apostrophes were restored: 186 strings moved to double quotes and started carrying a `'`,
#: and this stopped matching a single one of them. The check went on printing "ok" over 119
#: fewer words. A checker that quietly reads less than it thinks is worse than no checker,
#: because its silence gets taken for a pass.
PAIR = re.compile(r"""\['((?:ph|app)\.[a-z0-9_]+)'\]\s*=\s*(['"])((?:(?!\2)[^\\]|\\.)*)\2""")
ACC = re.compile('[à-ÿ]')
WORD = re.compile('[A-Za-zÀ-ÿ]+')

#: Both spellings are real French words. The sentence decides, so the file is allowed to hold
#: both and this check must stay quiet about them.
#:
#:   a / à            the verb, and the preposition
#:   la / là          the article, and "there"
#:   ou / où          "or", and "where"
#:   des / dès        the article, and "as soon as"
#:   votre / vôtre    the adjective, and the pronoun
#:   cause / causé    and every other present-tense-against-past-participle pair below
HOMOGRAPHS = {
    'a', 'la', 'ou', 'des', 'votre', 'sur', 'ete',
    # Present tense against past participle. Both are words; only the sentence tells them apart.
    'passe', 'compte', 'charge', 'chiffre', 'enregistre', 'supprime', 'ferme', 'aime',
    'arrive', 'retire', 'manque', 'refuse', 'termine', 'accepte', 'copie', 'marche',
    'masque', 'active', 'affiche', 'autorise', 'autorises', 'expire', 'quitte', 'annule',
    'paye', 'publie', 'demandes', 'ajoute', 'efface', 'bloque', 'modifie', 'verses',
    'propose', 'dure', 'abonne', 'indique', 'certifie', 'like', 'likes', 'matche',
    # 'Aucune note' is the noun and is correct; 'noté' is the participle. Both are real.
    'note', 'notes',
    # 'Le tirage commence' is the present tense; 'a commencé' is the participle.
    'commence',
}


#: Spellings that are not French words at all.
#:
#: **The self-consistency check above cannot see these.** `Telechargement` appeared five times
#: and never once with its accents, so there was no contradiction in the file to notice. A word
#: that is uniformly wrong is invisible to a check that compares the file against itself, and
#: the only way to catch one is to name it.
#:
#: Kept short and certain on purpose. Every entry is a string that no French sentence contains,
#: so a hit is a defect and never a matter of taste. Words where both spellings are real belong
#: in HOMOGRAPHS above, not here.
NOT_WORDS = {
    'telechargement', 'telechargements', 'telecharger', 'telecharge',
    'telephone', 'telephones', 'numero', 'numeros', 'ecran', 'ecrans',
    'reseau', 'reseaux', 'vehicule', 'vehicules', 'securite', 'depannage',
    'metier', 'metiers', 'proximite', 'depot', 'depots', 'bibliotheque',
    'hebergeur', 'hebergeurs', 'ecouteurs', 'deja', 'etes', 'etre',
    'meme', 'memes', 'arriere', 'reessayez', 'recu', 'recus', 'pret', 'prets',
    'definir', 'defini', 'definie', 'desactiver', 'desactive', 'desactivee',
    'apres', 'tres', 'etat', 'etats', 'energie', 'derniere', 'dernieres',
    'evenement', 'evenements', 'operateur', 'operation', 'operations',
    'francais', 'defaut', 'societe', 'societes', 'sante', 'acces', 'succes',
    'interet', 'interets', 'proprietaire', 'donnees', 'metres', 'kilometres',
    'general', 'generale', 'video', 'videos', 'reglages', 'reglage',
    'preference', 'preferences', 'echec', 'echoue',
    'verification', 'categorie', 'categories', 'identite', 'activite',
    'confidentialite', 'caracteres', 'caractere', 'mecanicien', 'etoiles',
    'necessaires', 'necessaire', 'resultat', 'resultats', 'piece', 'pieces',
    'banniere', 'bannieres', 'reponse', 'reponses', 'entree', 'entrees',
    'portee', 'apercu', 'apercus', 'prives', 'privee', 'privees', 'age',
    'repond', 'repondre', 'repondu', 'recoit', 'recoivent', 'creer', 'creez',
    'creee', 'creees', 'verifier', 'verifiez', 'deverrouille', 'deverrouiller',
    'arreter', 'arrete', 'inserer', 'etablir', 'gerer', 'preleve',
    'envoye', 'envoyee', 'envoyes', 'prevenu', 'prevenue',
    'apparait', 'retiree', 'terminee', 'utilisee', 'configuree', 'partagee',
    'chiffree', 'enregistree', 'installee', 'publiee', 'occupee', 'activee',
    'epinglee', 'epinglees', 'eloigne', 'abonnes', 'votres', 'prete',
    'debite', 'debitee', 'payee', 'demarre', 'demarrer', 'etape', 'etapes',
    'cloturee', 'arrivee', 'manques', 'rembourse', 'reference',
    'monoalphabetique', 'represente', 'frequente', 'retrouvees', 'equations',
    'plutot', 'refusee', 'decodee', 'fermee', 'facon', 'systeme',
    'deplace', 'numerotation', 'soiree', 'prefere', 'idee', 'idees',
    'annee', 'annees', 'journee', 'duree', 'element', 'elements', 'periode',
    'periodes', 'probleme', 'problemes', 'parametre', 'parametres',
    'modele', 'modeles', 'critere', 'criteres', 'numerique', 'electrique',
}


def words_of(path):
    src = io.open(path, encoding='utf-8').read()
    counts = collections.Counter()
    where = collections.defaultdict(list)
    for m in PAIR.finditer(src):
        for w in WORD.findall(m.group(3)):
            counts[w.lower()] += 1
            if len(where[w.lower()]) < 3:
                where[w.lower()].append(m.group(1))
    return counts, where


def plain(word):
    return ''.join(c for c in unicodedata.normalize('NFD', word)
                   if unicodedata.category(c) != 'Mn')


def main():
    counts, where = words_of(os.path.join(ROOT, 'locales', 'fr.lua'))

    accented = collections.defaultdict(set)
    for w in counts:
        if ACC.search(w):
            accented[plain(w)].add(w)

    problems = []
    for w, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        if ACC.search(w) or w not in accented or w in HOMOGRAPHS:
            continue
        forms = ', '.join(sorted(accented[w]))
        problems.append('%-16s x%-4d is also written %-16s  (%s)'
                        % (w, n, forms, ', '.join(where[w])))

    # And the ones the file is uniformly wrong about, which the comparison above cannot see.
    for w in sorted(NOT_WORDS):
        if counts.get(w):
            problems.append('%-16s x%-4d is not a French word           (%s)'
                            % (w, counts[w], ', '.join(where[w])))

    print('french spelling   %d word(s) checked' % len(counts))
    if not problems:
        print('  ok    no word is spelled two ways')
        return 0
    print('')
    for p in problems:
        print('  ' + p)
    print('')
    print('%d word(s) spelled both ways. Either the accent belongs on every one of them, or the'
          % len(problems))
    print('pair is a real homograph and belongs in HOMOGRAPHS at the top of this file.')
    return 1


if __name__ == '__main__':
    sys.exit(main())
