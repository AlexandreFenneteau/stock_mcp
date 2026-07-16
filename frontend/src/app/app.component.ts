import { Component, Inject, OnDestroy, OnInit } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormsModule } from '@angular/forms';
import {
  MSAL_GUARD_CONFIG,
  MsalBroadcastService,
  MsalGuardConfiguration,
  MsalService,
} from '@azure/msal-angular';
import {
  AuthenticationResult,
  EventMessage,
  EventType,
  InteractionStatus,
} from '@azure/msal-browser';
import { Subject } from 'rxjs';
import { filter, takeUntil } from 'rxjs/operators';
import { StockItem, StockService } from './stock.service';

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [CommonModule, FormsModule],
  templateUrl: './app.component.html',
  styleUrl: './app.component.css',
})
export class AppComponent implements OnInit, OnDestroy {
  title = 'Gestion de stock';

  items: StockItem[] = [];
  loading = false;
  errorMessage: string | null = null;
  pendingItemId: number | null = null;

  private readonly destroying$ = new Subject<void>();

  constructor(
    @Inject(MSAL_GUARD_CONFIG) private readonly msalGuardConfig: MsalGuardConfiguration,
    private readonly msalService: MsalService,
    private readonly msalBroadcastService: MsalBroadcastService,
    private readonly stockService: StockService,
  ) {}

  ngOnInit(): void {
    this.msalBroadcastService.msalSubject$
      .pipe(
        filter((msg: EventMessage) => msg.eventType === EventType.LOGIN_SUCCESS),
        takeUntil(this.destroying$),
      )
      .subscribe((result: EventMessage) => {
        const payload = result.payload as AuthenticationResult;
        this.msalService.instance.setActiveAccount(payload.account);
      });

    this.msalBroadcastService.inProgress$
      .pipe(
        filter((status: InteractionStatus) => status === InteractionStatus.None),
        takeUntil(this.destroying$),
      )
      .subscribe(() => {
        // On a fresh page load (no redirect response), MSAL does not
        // auto-select an active account even if one is cached — pick the
        // first available account so the UI can display the user's identity.
        if (!this.msalService.instance.getActiveAccount()) {
          const [firstAccount] = this.msalService.instance.getAllAccounts();
          if (firstAccount) {
            this.msalService.instance.setActiveAccount(firstAccount);
          }
        }

        if (this.isLoggedIn()) {
          this.loadStock();
        }
      });
  }

  ngOnDestroy(): void {
    this.destroying$.next();
    this.destroying$.complete();
  }

  isLoggedIn(): boolean {
    return this.msalService.instance.getAllAccounts().length > 0;
  }

  /**
   * Best available identifier for the signed-in user: full name (from the
   * "name" claim) if present, otherwise the UPN/email ("username"), otherwise
   * the account's local ID as a last resort.
   */
  get activeAccountName(): string | null {
    const account = this.msalService.instance.getActiveAccount();
    if (!account) {
      return null;
    }
    return account.name || account.username || account.localAccountId || null;
  }

  login(): void {
    this.msalService.loginRedirect(this.msalGuardConfig.authRequest as any);
  }

  logout(): void {
    this.msalService.logoutRedirect();
  }

  loadStock(): void {
    this.loading = true;
    this.errorMessage = null;
    this.stockService.list().subscribe({
      next: (items) => {
        this.items = items;
        this.loading = false;
      },
      error: () => {
        this.errorMessage = "Impossible de charger le stock.";
        this.loading = false;
      },
    });
  }

  adjust(item: StockItem, delta: number): void {
    if (this.pendingItemId !== null) {
      return;
    }
    this.pendingItemId = item.id;
    this.stockService.adjust({ id: item.id, quantity_change: delta }).subscribe({
      next: (updated) => {
        item.quantity = updated.quantity;
        this.pendingItemId = null;
      },
      error: () => {
        this.errorMessage = `Impossible d'ajuster l'article ${item.id}.`;
        this.pendingItemId = null;
      },
    });
  }
}
